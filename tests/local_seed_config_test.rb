# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'
require 'yaml'

# Exercises the Perl helper through its public command-line interface.
class LocalSeedConfigTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  HELPER = File.join(ROOT, 'prepare_local_seed.pl')
  VM_CONFIG = "bios: ovmf\nnet0: virtio=BC:24:11:12:34:56,bridge=vmbr0,firewall=1\n"

  # Isolate generated files so failed renders cannot damage repository profiles.
  def setup
    @directory = Dir.mktmpdir('local-seed-config-test')
    @input = File.join(@directory, 'input')
    @output = File.join(@directory, 'output')
    @config = File.join(@directory, 'vm-config')
    FileUtils.mkdir_p(@input)
    File.write(@config, VM_CONFIG)
    File.write(File.join(@input, 'user-data'), "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: [network, identity]}\n")
    File.write(File.join(@input, 'meta-data'), "instance-id: test\n")
  end

  # Remove only this test's temporary input and output files.
  def teardown
    FileUtils.remove_entry(@directory)
  end

  # Run a public helper command and retain diagnostics for failed assertions.
  # Args: command and arguments passed directly to Perl without shell expansion.
  def run_helper(*arguments, input: '')
    Open3.capture3('perl', HELPER, *arguments, stdin_data: input)
  end

  # Render with independently configurable network values and adapter selection.
  def render(ip: '10.0.0.34/24', gateway: '10.0.0.1', dns: nil, interface: 'net0', vmid: '103', input: @input, output: @output)
    arguments = ['render', '--ip', ip, '--gateway', gateway,
                 '--vm-config', @config, '--interface', interface, '--vmid', vmid,
                 '--input-dir', input, '--output-dir', output]
    arguments += ['--dns', dns] unless dns.nil?
    run_helper(*arguments)
  end

  # Parse generated YAML using a separate implementation to catch type changes.
  def load_yaml(path)
    YAML.safe_load_file(path, aliases: true)
  end

  def test_dns_defaults_to_gateway_and_explicit_dns_is_preserved
    [nil, '9.9.9.9'].each do |dns|
      FileUtils.rm_rf(@output)
      _stdout, stderr, status = render(dns: dns)
      assert status.success?, stderr
      network = load_yaml(File.join(@output, 'network-config'))
      nic = network.fetch('ethernets').fetch('install_nic')
      assert_equal ['10.0.0.34/24'], nic.fetch('addresses')
      assert_equal [dns || '10.0.0.1'], nic.fetch('nameservers').fetch('addresses')
      assert_equal [{ 'to' => 'default', 'via' => '10.0.0.1' }], nic.fetch('routes')
      assert_equal false, nic.fetch('dhcp4')
      refute nic.key?('dhcp6')
      refute nic.key?('accept-ra')
      refute nic.key?('set-name')
    end
  end

  def test_invalid_network_values_are_rejected
    invalid = [
      ['10.0.0.34', '10.0.0.1', nil],
      ['10.0.0.34/255.255.255.0', '10.0.0.1', nil],
      ['10.0.0.34/33', '10.0.0.1', nil],
      ['10.0.0.999/24', '10.0.0.1', nil],
      ['10.0.0.0/24', '10.0.0.1', nil],
      ['10.0.0.255/24', '10.0.0.1', nil],
      ['10.0.0.34/24', '10.0.1.1', nil],
      ['10.0.0.34/24', '10.0.0.0', nil],
      ['10.0.0.34/24', '10.0.0.255', nil],
      ['10.0.0.34/24', '10.0.0.34', nil],
      ['10.0.0.34/24', '10.0.0.1', ''],
      ['10.0.0.34/24', '10.0.0.1', 'dns.example.com'],
      ['10.0.0.34/24', '10.0.0.1', '224.0.0.1'],
      ['127.0.0.1/8', '127.0.0.2', nil],
      ['0.0.0.1/24', '0.0.0.2', nil],
      ['224.0.0.2/24', '224.0.0.1', nil],
      ['240.0.0.2/24', '240.0.0.1', nil],
      ['::1/128', '::2', nil],
      ['10.0.0.34/24', '::1', nil],
      ['10.0.0.034/24', '10.0.0.1', nil],
      ['10.1/24', '10.0.0.1', nil]
    ]
    invalid.each do |ip, gateway, dns|
      options = ['validate-network', '--ip', ip, '--gateway', gateway]
      options += ['--dns', dns] unless dns.nil?
      stdout, stderr, status = run_helper(*options)
      refute status.success?, options.inspect
      assert_empty stdout
      assert_includes stderr, 'ERROR:'
      refute File.exist?(@output)
    end
  end

  def test_31_peers_and_32_on_link_route
    ['10.0.0.0/31', '10.0.0.34/32'].each do |ip|
      FileUtils.rm_rf(@output)
      _stdout, stderr, status = render(ip: ip)
      assert status.success?, stderr
      route = load_yaml(File.join(@output, 'network-config')).fetch('ethernets').fetch('install_nic').fetch('routes').first
      if ip.end_with?('/32')
        assert_equal true, route.fetch('on-link')
      else
        refute route.key?('on-link')
      end
    end
  end

  def test_selects_nic_by_proxmox_key_and_matches_mac
    File.write(@config, VM_CONFIG + "net1: e1000=02:12:34:56:78:9A,bridge=vmbr1\n")
    _stdout, stderr, status = render(interface: 'net1')
    assert status.success?, stderr
    nic = load_yaml(File.join(@output, 'network-config')).fetch('ethernets').fetch('install_nic')
    assert_equal({ 'macaddress' => '02:12:34:56:78:9a' }, nic.fetch('match'))
  end

  def test_missing_disabled_or_malformed_adapter_is_rejected
    invalid = [
      [VM_CONFIG, 'net1'], [VM_CONFIG, 'ens18'], [VM_CONFIG + VM_CONFIG, 'net0'],
      ['net0: virtio=BC:24:11:12:34:56,link_down=1', 'net0'],
      ['net0: virtio=BC:24:11:12:34:56,link_down=on', 'net0'],
      ['net0: virtio=invalid', 'net0'],
      ['net0: virtio=00:00:00:00:00:00', 'net0'],
      ['net0: virtio=01:00:00:00:00:01', 'net0'],
      ['net0: virtio=BC:24:11:12:34:56,virtio=02:12:34:56:78:9a', 'net0'],
      ['net0: virtio=BC:24:11:12:34:56,e1000=02:12:34:56:78:9a', 'net0'],
      ['net0: bridge=vmbr0', 'net0'],
      ['net0: virtio=BC:24:11:12:34:56,malformed', 'net0']
    ]
    invalid.each do |config, interface|
      File.write(@config, config)
      _stdout, stderr, status = render(interface: interface)
      refute status.success?, config
      assert_includes stderr, 'ERROR:'
      refute File.exist?(@output)
    end
  end

  def test_every_profile_preserves_storage_identity_and_ipv6_settings
    paths = Dir.glob(File.join(ROOT, 'profiles/*/*/user-data')).sort
    refute_empty paths
    instance_ids = []
    paths.each do |path|
      FileUtils.rm_rf(@output)
      original_bytes = File.binread(path)
      original = load_yaml(path)
      original_meta = load_yaml(File.join(File.dirname(path), 'meta-data'))
      _stdout, stderr, status = render(input: File.dirname(path))
      assert status.success?, stderr
      actual = load_yaml(File.join(@output, 'user-data'))
      network = load_yaml(File.join(@output, 'network-config'))
      expected = Marshal.load(Marshal.dump(original))
      expected.fetch('autoinstall')['network'] = network
      expected.fetch('autoinstall')['interactive-sections'] = ['identity']
      assert_equal expected, actual, path
      assert File.read(File.join(@output, 'user-data')).start_with?("#cloud-config\n")
      metadata = load_yaml(File.join(@output, 'meta-data'))
      refute_equal original_meta.fetch('instance-id'), metadata.fetch('instance-id')
      assert_match(/\Aiid-autoinstall-103-[0-9a-f]{32}\z/, metadata.fetch('instance-id'))
      assert_equal original_meta.reject { |key, _| key == 'instance-id' }, metadata.reject { |key, _| key == 'instance-id' }
      instance_ids << metadata.fetch('instance-id')
      assert_equal({}, load_yaml(File.join(@output, 'vendor-data')))
      assert_equal original_bytes, File.binread(path)
    end
    assert_equal instance_ids.uniq, instance_ids
  end

  def test_yaml_scalar_types_unicode_and_shell_text_survive_rendering
    config = load_yaml(File.join(@input, 'user-data'))
    config['fixture'] = { 'yes' => true, 'no' => false, 'empty' => nil, 'integer' => 1,
                          'decimal' => 1.5, 'numeric_string' => '1', 'boolean_string' => 'false',
                          'unicode' => 'España', 'shell_text' => 'test ! -e /tmp/example' }
    File.write(File.join(@input, 'user-data'), "#cloud-config\n" + YAML.dump(config))
    _stdout, stderr, status = render
    assert status.success?, stderr
    assert_equal config.fetch('fixture'), load_yaml(File.join(@output, 'user-data')).fetch('fixture')
  end

  def test_invalid_profile_documents_do_not_create_output
    invalid = [
      "autoinstall:\n  version: 1\n  storage: {}\n",
      "#cloud-config\n- not-a-mapping\n",
      "#cloud-config\nautoinstall: false\n",
      "#cloud-config\nautoinstall: {version: true, storage: {}}\n",
      "#cloud-config\nautoinstall: {version: 2, storage: {}}\n",
      "#cloud-config\nautoinstall: {version: 1}\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: network}\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: null}\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: [1]}\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}, interactive-sections: ['*']}\n",
      "#cloud-config\nautoinstall: [\n",
      "#cloud-config\n!!python/object/apply:os.system ['false']\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}, storage: {layout: {name: direct}}}\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}}\n---\nsecond: document\n",
      "#cloud-config\nautoinstall: {version: 1, storage: {}}\nfixture: !!perl/code '{}'\n"
    ]
    invalid.each do |content|
      File.write(File.join(@input, 'user-data'), content)
      _stdout, stderr, status = render
      refute status.success?, content
      assert_includes stderr, 'ERROR:'
      refute File.exist?(@output)
    end
  end

  def test_bad_metadata_vmid_and_occupied_output_are_rejected
    File.write(File.join(@input, 'meta-data'), '[]')
    _stdout, _stderr, status = render
    refute status.success?
    refute File.exist?(@output)
    File.write(File.join(@input, 'meta-data'), '{}')
    ['0', '-1', 'true', 'vm103'].each do |vmid|
      _stdout, _stderr, status = render(vmid: vmid)
      refute status.success?, vmid
    end
    _stdout, _stderr, status = render(output: @input)
    refute status.success?
    FileUtils.mkdir_p(@output)
    sentinel = File.join(@output, 'sentinel')
    File.write(sentinel, 'keep')
    _stdout, _stderr, status = render
    refute status.success?
    assert_equal 'keep', File.read(sentinel)
  end

  def test_missing_files_report_concise_errors
    File.unlink(@config)
    _stdout, stderr, status = render
    refute status.success?
    assert_includes stderr, 'ERROR:'
    refute File.exist?(@output)
  end

  def test_digest_requires_a_json_object_with_valid_sha1
    digest = 'ab' * 20
    stdout, stderr, status = run_helper('read-digest', input: JSON.generate('digest' => digest))
    assert status.success?, stderr
    assert_equal "#{digest}\n", stdout
    ['{}', 'null', '[]', '{', '{"digest":42}', '{"digest":"invalid"}', '{"digest":true}'].each do |json|
      stdout, stderr, status = run_helper('read-digest', input: json)
      refute status.success?, json
      assert_empty stdout
      assert_includes stderr, 'ERROR:'
    end
  end

  def test_generated_ids_are_unique_hex_strings
    ids = Array.new(2) do
      stdout, stderr, status = run_helper('new-id')
      assert status.success?, stderr
      assert_match(/\A[0-9a-f]{32}\n\z/, stdout)
      stdout
    end
    refute_equal ids[0], ids[1]
  end
end
