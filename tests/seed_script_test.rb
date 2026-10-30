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
      if [[ "$1" == config ]]; then
        printf '%s\\n' "${QM_CONFIG:-}"
        exit "${QM_CONFIG_STATUS:-0}"
      fi
    SH
    FileUtils.chmod(0o755, qm)
    @env = { 'PATH' => "#{@directory}:#{ENV.fetch('PATH')}", 'QM_LOG' => @log,
             'QM_CONFIG' => '', 'QM_CONFIG_STATUS' => '0' }
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_each_profile_produces_the_expected_seed_url
    Dir.glob(File.expand_path('../profiles/*/*/user-data', __dir__)).sort.each do |path|
      profile = File.basename(File.dirname(path))
      firmware = File.basename(File.dirname(File.dirname(path)))
      config = firmware == 'uefi' ? 'bios: ovmf' : 'bios: seabios'
      FileUtils.rm_f(@log)
      stdout, stderr, status = Open3.capture3(@env.merge('QM_CONFIG' => config), 'bash', SCRIPT, '120', 'pavelsg/ubuntu-autoinstall', profile)
      assert status.success?, stderr
      url = "https://raw.githubusercontent.com/pavelsg/ubuntu-autoinstall/main/profiles/#{firmware}/#{profile}/"
      assert_includes stdout, url
      set_command = File.readlines(@log, chomp: true).last
      encoded = set_command.match(/\Aset 120 --smbios1 base64=1,serial=(\S+)\z/)
      refute_nil encoded, set_command
      assert_equal "ds=nocloud-net;s=#{url}", Base64.strict_decode64(encoded[1])
    end
  end

  def test_existing_smbios_is_not_replaced
    _stdout, stderr, status = Open3.capture3(@env.merge('QM_CONFIG' => 'smbios1: uuid=existing'), 'bash', SCRIPT, '120', 'owner/repo', 'single-disk')
    refute status.success?
    assert_includes stderr, 'already has smbios1 settings'
    refute File.readlines(@log).any? { |line| line.start_with?('set ') }
  end

  def test_custom_ref_is_used_in_seed_url
    stdout, stderr, status = Open3.capture3(@env.merge('QM_CONFIG' => 'bios: ovmf'), 'bash', SCRIPT, '120', 'owner/repo', 'single-disk', 'v1.0')
    assert status.success?, stderr
    assert_includes stdout, 'https://raw.githubusercontent.com/owner/repo/v1.0/profiles/uefi/single-disk/'
  end

  def test_missing_bios_setting_selects_bios_profile
    stdout, stderr, status = Open3.capture3(@env.merge('QM_CONFIG' => 'name: example'), 'bash', SCRIPT, '120', 'owner/repo', 'single-disk')
    assert status.success?, stderr
    assert_includes stdout, '/profiles/bios/single-disk/'
  end

  def test_unknown_firmware_does_not_change_vm
    _stdout, stderr, status = Open3.capture3(@env.merge('QM_CONFIG' => 'bios: unknown'), 'bash', SCRIPT, '120', 'owner/repo', 'single-disk')
    refute status.success?
    assert_includes stderr, 'Unsupported VM firmware'
    refute File.readlines(@log).any? { |line| line.start_with?('set ') }
  end

  def test_failed_config_read_does_not_fall_back_to_bios
    _stdout, _stderr, status = Open3.capture3(@env.merge('QM_CONFIG_STATUS' => '1'), 'bash', SCRIPT, '120', 'owner/repo', 'single-disk')
    refute status.success?
    refute File.readlines(@log).any? { |line| line.start_with?('set ') }
  end

  def test_invalid_arguments_do_not_call_qm
    _stdout, _stderr, status = Open3.capture3(@env, 'bash', SCRIPT, '120', 'owner/repo', '../invalid')
    refute status.success?
    refute File.exist?(@log)
  end
end
