# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'minitest/autorun'
require 'open3'
require 'rbconfig'
require 'tmpdir'
require 'yaml'

# Exercises the real seed renderer and CLI without accessing a host or network.
class LocalSeedCliTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  SCRIPT = File.join(ROOT, 'set-proxmox-seed.sh')
  UUID = '10e77876-6ab6-48dc-888b-05df0d1f7d62'
  MAC = 'BC:24:11:12:34:56'
  BASE_CONFIG = "smbios1: uuid=#{UUID}\n" \
                "net0: virtio=#{MAC},bridge=vmbr0\n" \
                "ide2: local:iso/ubuntu-server.iso,media=cdrom\n" \
                'scsi0: local-lvm:vm-103-disk-0,size=32G'

  # The adapters share a fixture so tests can inspect mutations and inject failures.
  MOCK_COMMAND = <<~'RUBY'
    require 'fileutils'
    require 'json'

    state_path = ENV.fetch('SEED_TEST_STATE')
    state = JSON.parse(File.read(state_path))
    name = File.basename($PROGRAM_NAME)
    args = ARGV
    File.open(state.fetch('log'), 'a') { |log| log.puts(JSON.generate([name, *args])) }
    exit 1 if [name, "#{name} #{args.first}"].include?(state['fail'])

    case name
    when 'qm'
      case args.first
      when 'status'
        puts "status: #{state.fetch('status', 'stopped')}"
      when 'config'
        count = state.fetch('config_reads', 0) + 1
        state['config_reads'] = count
        File.write(state_path, JSON.generate(state))
        puts state.fetch('config')
        puts 'name: changed-during-download' if count > 1 && state['change_config']
      when 'set'
        # Successful updates are recorded by the shared command log above.
      else
        exit 2
      end
    when 'pvesm'
      case args.first
      when 'status'
        storage = args.fetch(args.index('--storage') + 1)
        puts 'Name Type Status Total Used Available %'
        puts "#{storage} dir #{state.fetch('storage_status', 'active')} 100 0 100 0"
      when 'path'
        puts File.join(state.fetch('storage_dir'), args.fetch(1).split('/', 2).last)
      else
        exit 2
      end
    when 'pvesh'
      puts JSON.generate('digest' => state.fetch('digest', 'f' * 40))
    when 'curl'
      output = args.fetch(args.index('--output') + 1)
      if state['bad_yaml']
        File.write(output, '<html>not a profile</html>')
      else
        relative = args.last.split('/profiles/', 2).fetch(1)
        FileUtils.cp(File.join(state.fetch('repo'), 'profiles', relative), output)
      end
    when 'genisoimage'
      contents = args.last(4).to_h { |filename| [filename, File.read(filename)] }
      File.write(state.fetch('capture'), JSON.generate(contents))
      File.write(args.fetch(args.index('-output') + 1), 'mock ISO artifact')
    else
      # Interpreter stubs fail visibly if the production path regresses.
      exit 2
    end
  RUBY

  # Creates isolated command adapters and storage for each test.
  def setup
    @directory = Dir.mktmpdir('local-seed-cli-test')
    @bin_dir = File.join(@directory, 'bin')
    @storage_dir = File.join(@directory, 'storage')
    FileUtils.mkdir_p([@bin_dir, @storage_dir])
    @state_path = File.join(@directory, 'state.json')
    @state = {
      'log' => File.join(@directory, 'commands.jsonl'),
      'capture' => File.join(@directory, 'seed.json'),
      'storage_dir' => @storage_dir,
      'repo' => ROOT,
      'config' => BASE_CONFIG.dup
    }
    save_state
    %w[qm pvesm pvesh curl genisoimage python python3].each do |command|
      path = File.join(@bin_dir, command)
      File.write(path, "#!#{RbConfig.ruby}\n#{MOCK_COMMAND}")
      FileUtils.chmod(0o755, path)
    end
    @env = { 'PATH' => "#{@bin_dir}:#{ENV.fetch('PATH')}", 'SEED_TEST_STATE' => @state_path }
  end

  # Removes temporary seed artifacts and adapters even after assertion failures.
  def teardown
    FileUtils.remove_entry(@directory)
  end

  # Verifies rendered networking, retained profile settings and isolated VM updates.
  def test_static_seed_defaults_dns_to_gateway_and_keeps_existing_media
    _stdout, stderr, status = run_cli
    assert status.success?, stderr
    files = JSON.parse(File.read(@state.fetch('capture')))
    config = YAML.safe_load(files.fetch('user-data')).fetch('autoinstall')
    network = YAML.safe_load(files.fetch('network-config'))
    assert_equal config.fetch('network'), network
    nic = network.fetch('ethernets').fetch('install_nic')
    assert_equal ['10.0.0.34/24'], nic.fetch('addresses')
    assert_equal ['10.0.0.1'], nic.fetch('nameservers').fetch('addresses')
    assert_equal MAC.downcase, nic.fetch('match').fetch('macaddress')
    assert_equal false, nic.fetch('dhcp4')
    assert_equal ['identity'], config.fetch('interactive-sections')
    assert config.key?('late-commands')
    updates = commands.select { |command| command.first(2) == %w[qm set] }
    assert_equal 1, updates.length
    update = updates.first
    assert_includes update, '--ide3'
    refute_includes update, '--ide2'
    refute_includes update, '--scsi0'
    assert_equal 'f' * 40, update.fetch(update.index('--digest') + 1)
    smbios = update.fetch(update.index('--smbios1') + 1)
    assert_includes smbios, "uuid=#{UUID}"
    assert_includes smbios, 'serial=ZHM9bm9jbG91ZA=='
    assert_includes update.last, 'local:iso/autoinstall-seed-103-'
    iso_command = commands.find { |command| command.first == 'genisoimage' }
    assert_equal 'cidata', iso_command.fetch(iso_command.index('-volid') + 1)
    assert_equal %w[user-data meta-data network-config vendor-data], iso_command.last(4)
    assert_equal 1, Dir.glob(File.join(@storage_dir, '*.iso')).length
    assert_empty Dir.children(@storage_dir).grep(/^\./)
  end

  # Ensures the host path succeeds while both removed interpreter names fail.
  def test_static_seed_does_not_invoke_python
    _stdout, stderr, status = run_cli
    assert status.success?, stderr
    refute commands.any? { |command| %w[python python3].include?(command.first) }
  end

  # Checks explicit NIC, DNS, storage and slot options against a real UEFI profile.
  def test_overrides_use_uefi_selected_nic_dns_storage_and_slot
    @state['config'] += "\nbios: ovmf\nnet1: e1000=02:00:00:00:00:02,bridge=vmbr1"
    save_state
    _stdout, stderr, status = run_cli('--dns', '1.1.1.1', '--interface', 'net1', '--storage', 'isos', '--seed-slot', 'sata5')
    assert status.success?, stderr
    files = JSON.parse(File.read(@state.fetch('capture')))
    config = YAML.safe_load(files.fetch('user-data')).fetch('autoinstall')
    nic = config.fetch('network').fetch('ethernets').fetch('install_nic')
    assert_equal ['1.1.1.1'], nic.fetch('nameservers').fetch('addresses')
    assert_equal '02:00:00:00:00:02', nic.fetch('match').fetch('macaddress')
    assert config.fetch('storage').fetch('config').any? { |action| action['path'] == '/boot/efi' }
    update = commands.find { |command| command.first(2) == %w[qm set] }
    assert_includes update, '--sata5'
    assert update.last.start_with?('isos:iso/')
  end

  # Prevents competing seed media while preserving the previous recovery artifact.
  def test_existing_seed_slot_is_reused_and_previous_iso_is_preserved
    old_name = "autoinstall-seed-103-#{'a' * 32}.iso"
    old_iso = File.join(@storage_dir, old_name)
    File.write(old_iso, 'previous seed')
    @state['config'] += "\nide1: local:iso/#{old_name},media=cdrom"
    @state['config'] = @state.fetch('config').sub("uuid=#{UUID}", "uuid=#{UUID},base64=1,serial=ZHM9bm9jbG91ZA==")
    save_state
    _stdout, stderr, status = run_cli
    assert status.success?, stderr
    update = commands.find { |command| command.first(2) == %w[qm set] }
    assert_includes update, '--ide1'
    refute_includes update, '--ide3'
    assert_equal 'previous seed', File.read(old_iso)
    assert_equal 2, Dir.glob(File.join(@storage_dir, '*.iso')).length
  end

  # Requires automatic slot selection to preserve existing media.
  def test_automatic_slot_selection_skips_existing_devices
    @state['config'] += "\nide3: local:iso/tools.iso,media=cdrom"
    save_state
    _stdout, stderr, status = run_cli
    assert status.success?, stderr
    update = commands.find { |command| command.first(2) == %w[qm set] }
    assert_includes update, '--ide1'
    refute_includes update, '--ide3'
  end

  # Rejects malformed options before contacting any host-facing command.
  def test_invalid_options_stop_before_proxmox_commands
    examples = [
      ['--ip', '10.0.0.34/24'],
      ['--gateway', '10.0.0.1'],
      ['--ip', '10.0.0.34', '--gateway', '10.0.0.1'],
      ['--ip', '10.0.0.999/24', '--gateway', '10.0.0.1'],
      ['--ip', '10.0.0.34/24', '--gateway', '10.0.0.1', '--dns', 'invalid'],
      ['--ip', '10.0.0.34/24', '--gateway', '10.0.0.1', '--ip', '10.0.0.35/24'],
      ['--ip'], ['--ip', '--gateway'], ['--unknown', 'value']
    ]
    examples.each do |options|
      _stdout, stderr, status = run_cli(*options, static: false)
      refute status.success?, "#{options.inspect}: #{stderr}"
      assert_empty commands, options.inspect
    end
  end

  # Covers failed preparation, occupied media and concurrent VM configuration edits.
  def test_preparation_failures_never_modify_vm_or_leave_partial_iso
    examples = [
      { 'fail' => 'curl' }, { 'bad_yaml' => true }, { 'fail' => 'genisoimage' },
      { 'storage_status' => 'inactive' }, { 'status' => 'running' }, { 'digest' => 'invalid' },
      { 'config' => "#{BASE_CONFIG}\nide3: local-lvm:vm-103-disk-1,size=10G", 'options' => ['--seed-slot', 'ide3'] },
      { 'config' => "#{BASE_CONFIG}\nide0: disk0\nide1: disk1\nide3: disk3" },
      { 'config' => BASE_CONFIG.sub('net0:', 'net1:') },
      { 'config' => "#{BASE_CONFIG}\nide0: local-lvm:vm-103-cloudinit,media=cdrom" },
      { 'change_config' => true }
    ]
    examples.each do |behavior|
      @state.merge!('config' => BASE_CONFIG, 'config_reads' => 0)
      @state.merge!(behavior.reject { |key, _value| key == 'options' })
      save_state
      FileUtils.rm_f(@state.fetch('log'))
      stdout, stderr, status = run_cli(*behavior.fetch('options', []))
      refute status.success?, "#{behavior.inspect}: #{stdout}\n#{stderr}"
      assert_no_vm_update
      assert_empty Dir.children(@storage_dir), behavior.inspect
      behavior.each_key { |key| @state.delete(key) unless %w[config options].include?(key) }
    end
  end

  # Keeps a completed ISO for inspection when attaching it fails ambiguously.
  def test_failed_attach_retains_generated_iso_for_inspection
    @state['fail'] = 'qm set'
    save_state
    _stdout, stderr, status = run_cli
    refute status.success?
    assert_includes stderr, 'generated ISO retained'
    assert_equal 1, Dir.glob(File.join(@storage_dir, '*.iso')).length
    assert_empty Dir.children(@storage_dir).grep(/^\./)
  end

  # Prevents an existing local seed from silently overriding the requested web seed.
  def test_web_mode_refuses_a_competing_local_seed
    @state['config'] += "\nide3: local:iso/autoinstall-seed-103-#{'a' * 32}.iso,media=cdrom"
    save_state
    _stdout, stderr, status = run_cli(static: false)
    refute status.success?
    assert_includes stderr, 'Detach the generated local seed'
    assert_no_vm_update
  end

  private

  # Writes the adapter fixture; each test owns its isolated configuration.
  def save_state
    File.write(@state_path, JSON.generate(@state))
  end

  # Runs the real CLI with captured output and optional standard static networking.
  #
  # Args:
  #   options: Extra CLI arguments after repository and profile selection.
  #   static: Whether to include the standard test address and gateway.
  #
  # Returns:
  #   The stdout, stderr and Process::Status tuple from Open3.capture3.
  def run_cli(*options, static: true)
    arguments = ['bash', SCRIPT, '103', 'pavelsg/ubuntu-autoinstall', 'single-disk-noipv6', 'main']
    arguments.concat(['--ip', '10.0.0.34/24', '--gateway', '10.0.0.1']) if static
    Open3.capture3(@env, *arguments, *options)
  end

  # Returns the host commands observed by the fixture adapters, in invocation order.
  def commands
    log = @state.fetch('log')
    File.exist?(log) ? File.readlines(log, chomp: true).map { |line| JSON.parse(line) } : []
  end

  # Requires that validation and preparation failures never mutate VM configuration.
  def assert_no_vm_update
    refute commands.any? { |command| command.first(2) == %w[qm set] }
  end
end
