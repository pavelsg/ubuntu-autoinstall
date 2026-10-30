# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Checks the installer choices shared by every NoCloud profile.
class ProfileSettingsTest < Minitest::Test
  def test_each_profile_has_both_firmware_flavors_and_unique_instance_ids
    profiles_dir = File.expand_path('../profiles', __dir__)
    instance_ids = []
    assert_equal %w[bios uefi], Dir.children(profiles_dir).sort
    profiles = Dir.children(File.join(profiles_dir, 'bios')).sort
    refute_empty profiles
    %w[bios uefi].each do |firmware|
      directory = File.join(profiles_dir, firmware)
      assert_equal profiles, Dir.children(directory).sort, firmware
      profiles.each do |profile|
        flavor = File.join(directory, profile)
        assert File.file?(File.join(flavor, 'user-data')), flavor
        instance_ids << YAML.safe_load_file(File.join(flavor, 'meta-data')).fetch('instance-id')
      end
    end
    assert_equal instance_ids.uniq, instance_ids
  end

  def test_all_profiles_have_the_required_installer_choices
    profiles = Dir.glob(File.expand_path('../profiles/*/*/user-data', __dir__)).sort
    refute_empty profiles, 'No autoinstall profiles found'

    profiles.each do |path|
      config = YAML.safe_load_file(path).fetch('autoinstall')
      assert_equal 'en_US.UTF-8', config.fetch('locale'), path
      assert_equal({ 'layout' => 'us', 'variant' => '' }, config.fetch('keyboard'), path)
      assert_equal 'ubuntu-server-minimal', config.fetch('source').fetch('id'), path
      assert_nil config.fetch('proxy'), path
      assert_equal [], config.fetch('snaps'), path
      assert_equal %w[network identity], config.fetch('interactive-sections'), path
    end
  end

  def test_single_disk_profiles_use_sda_without_lvm_or_mysql_mounts
    %w[bios uefi].each do |firmware|
      directory = File.expand_path("../profiles/#{firmware}/single-disk", __dir__)
      config = YAML.safe_load_file(File.join(directory, 'user-data')).fetch('autoinstall')
      actions = config.fetch('storage').fetch('config')
      disks = actions.select { |action| action.fetch('type') == 'disk' }
      assert_equal 1, disks.length, firmware
      assert_equal '/dev/sda', disks.first.fetch('path'), firmware
      assert_equal 'gpt', disks.first.fetch('ptable'), firmware
      assert_equal 'superblock-recursive', disks.first.fetch('wipe'), firmware
      refute actions.any? { |action| action.fetch('type').start_with?('lvm_') }, firmware

      root = actions.find { |action| action['id'] == 'root_partition' }
      assert_equal 'os_disk', root.fetch('device'), firmware
      assert_equal(-1, root.fetch('size'), firmware)
      assert_includes actions, { 'type' => 'format', 'id' => 'fs_root', 'fstype' => 'ext4', 'volume' => 'root_partition' }
      mounts = actions.select { |action| action.fetch('type') == 'mount' }
      assert_equal firmware == 'uefi' ? ['/', '/boot/efi'] : ['/'], mounts.map { |mount| mount.fetch('path') }, firmware
      assert_equal "iid-ubuntu26-single-disk-#{firmware}", YAML.safe_load_file(File.join(directory, 'meta-data')).fetch('instance-id')

      if firmware == 'bios'
        assert_equal true, disks.first.fetch('grub_device')
        assert_includes actions, { 'type' => 'partition', 'id' => 'bios_grub', 'device' => 'os_disk', 'size' => '1M', 'flag' => 'bios_grub' }
      else
        assert_includes actions, { 'type' => 'partition', 'id' => 'esp', 'device' => 'os_disk', 'size' => '1G', 'flag' => 'boot', 'grub_device' => true }
        assert_includes actions, { 'type' => 'format', 'id' => 'fs_esp', 'fstype' => 'fat32', 'volume' => 'esp' }
      end
    end
  end

  def test_single_disk_profiles_match_standard_mysql_profiles_outside_storage
    %w[bios uefi].each do |firmware|
      profiles_dir = File.expand_path('../profiles', __dir__)
      mysql = YAML.safe_load_file(File.join(profiles_dir, firmware, "mysql-2disk", 'user-data')).fetch('autoinstall')
      single = YAML.safe_load_file(File.join(profiles_dir, firmware, "single-disk", 'user-data')).fetch('autoinstall')
      assert_equal mysql.reject { |key, _| key == 'storage' },
                   single.reject { |key, _| key == 'storage' }, firmware
    end
  end
end
