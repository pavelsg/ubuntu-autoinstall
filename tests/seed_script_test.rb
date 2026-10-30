# frozen_string_literal: true

require 'base64'
require 'fileutils'
require 'minitest/autorun'
require 'open3'
require 'tmpdir'

# Exercises seed generation without accessing a Proxmox host.
class SeedScriptTest < Minitest::Test
  SCRIPT = File.expand_path('../set-proxmox-seed.sh', __dir__)

  def setup
    @directory = Dir.mktmpdir('seed-script-test')
    @log = File.join(@directory, 'qm.log')
    qm = File.join(@directory, 'qm')
    File.write(qm, <<~SH)
      #!/usr/bin/env bash
      printf '%s\\n' "$*" >> "$QM_LOG"
      if [[ "$1" == config && "${QM_EXISTING_SMBIOS:-}" == 1 ]]; then
        printf '%s\\n' 'smbios1: uuid=existing'
      fi
    SH
    FileUtils.chmod(0o755, qm)
    @env = { 'PATH' => "#{@directory}:#{ENV.fetch('PATH')}", 'QM_LOG' => @log }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_each_profile_produces_the_expected_seed_url
    Dir.glob(File.expand_path('../profiles/*/user-data', __dir__)).sort.each do |path|
      profile = File.basename(File.dirname(path))
      FileUtils.rm_f(@log)
      stdout, stderr, status = Open3.capture3(@env, 'bash', SCRIPT, '120', 'pavelsg/ubuntu-autoinstall', profile)
      assert status.success?, stderr
      url = "https://raw.githubusercontent.com/pavelsg/ubuntu-autoinstall/main/profiles/#{profile}/"
      assert_includes stdout, url
      set_command = File.readlines(@log, chomp: true).last
      encoded = set_command.match(/\Aset 120 --smbios1 base64=1,serial=(\S+)\z/)
      refute_nil encoded, set_command
      assert_equal "ds=nocloud-net;s=#{url}", Base64.strict_decode64(encoded[1])
    end
  end

  def test_existing_smbios_is_not_replaced
    _stdout, stderr, status = Open3.capture3(@env.merge('QM_EXISTING_SMBIOS' => '1'), 'bash', SCRIPT, '120', 'owner/repo', 'single-disk-bios')
    refute status.success?
    assert_includes stderr, 'already has smbios1 settings'
    refute File.readlines(@log).any? { |line| line.start_with?('set ') }
  end

  def test_custom_ref_is_used_in_seed_url
    stdout, stderr, status = Open3.capture3(@env, 'bash', SCRIPT, '120', 'owner/repo', 'single-disk-uefi', 'v1.0')
    assert status.success?, stderr
    assert_includes stdout, 'https://raw.githubusercontent.com/owner/repo/v1.0/profiles/single-disk-uefi/'
  end

  def test_invalid_arguments_do_not_call_qm
    _stdout, _stderr, status = Open3.capture3(@env, 'bash', SCRIPT, '120', 'owner/repo', '../invalid')
    refute status.success?
    refute File.exist?(@log)
  end
end
