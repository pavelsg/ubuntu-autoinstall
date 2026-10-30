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

  # Subiquity requires the path argument even for swap. Its own swap creation
  # uses an empty string, which Curtin translates to "none" in /etc/fstab.
  def test_mounts_have_explicit_paths_including_swap
    Dir.glob(File.expand_path('../profiles/*/*/user-data', __dir__)).sort.each do |path|
      actions = YAML.safe_load_file(path).fetch('autoinstall').fetch('storage').fetch('config')
      by_id = actions.to_h { |action| [action.fetch('id'), action] }
      mounts = actions.select { |action| action.fetch('type') == 'mount' }
      refute_empty mounts, path
      mounts.each do |mount|
        message = "#{path}: #{mount.fetch('id')}"
        assert mount.key?('path'), "#{message} must supply Subiquity's required path argument"
        assert_kind_of String, mount.fetch('path'), message
        filesystem = by_id.fetch(mount.fetch('device'))
        assert_equal 'format', filesystem.fetch('type'), message
        if filesystem.fetch('fstype') == 'swap'
          assert_equal '', mount.fetch('path'), message
        else
          assert mount.fetch('path').start_with?('/'), message
        end
      end
    end
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

  # Compare the complete OS action graph so sizes, formats, mounts and boot flags
  # cannot drift from the matching MySQL profile when either layout is edited.
  def test_single_disk_profiles_match_mysql_os_storage_on_sda
    %w[bios uefi].product(['', '-noipv6']).each do |firmware, suffix|
      directory = File.expand_path("../profiles/#{firmware}/single-disk#{suffix}", __dir__)
      config = YAML.safe_load_file(File.join(directory, 'user-data')).fetch('autoinstall')
      mysql_path = File.expand_path("../profiles/#{firmware}/mysql-2disk#{suffix}/user-data", __dir__)
      mysql_storage = YAML.safe_load_file(mysql_path).fetch('autoinstall').fetch('storage')
      # Storage actions are ordered by dependency. Retain only os_disk and the
      # actions that depend on it, excluding the entire database disk graph.
      os_ids = ['os_disk']
      expected_actions = mysql_storage.fetch('config').select do |action|
        dependencies = [action['device'], action['volume'], action['volgroup'], *action.fetch('devices', [])].compact
        belongs_to_os = action.fetch('id') == 'os_disk' || dependencies.any? { |id| os_ids.include?(id) }
        os_ids << action.fetch('id') if belongs_to_os
        belongs_to_os
      end
      expected_actions.first.delete('match')
      expected_actions.first['path'] = '/dev/sda'
      assert_equal mysql_storage.merge('config' => expected_actions), config.fetch('storage'), directory

      actions = config.fetch('storage').fetch('config')
      disks = actions.select { |action| action.fetch('type') == 'disk' }
      assert_equal 1, disks.length, firmware
      assert_equal '/dev/sda', disks.first.fetch('path'), firmware
      assert_equal 'gpt', disks.first.fetch('ptable'), firmware
      assert_equal 'superblock-recursive', disks.first.fetch('wipe'), firmware
      assert_equal ['vg_os'], actions.select { |action| action['type'] == 'lvm_volgroup' }.map { |action| action.fetch('name') }
      assert_equal 0, config.fetch('storage').fetch('swap').fetch('size')
      mounts = actions.select { |action| action.fetch('type') == 'mount' }
      paths = ['/', '/boot', '/var', '/var/log', '/home']
      paths << '/boot/efi' if firmware == 'uefi'
      assert_equal paths.sort, mounts.map { |mount| mount.fetch('path') }.reject(&:empty?).sort, firmware
      assert_includes mounts, { 'type' => 'mount', 'id' => 'mount_swap', 'device' => 'fs_os_swap', 'path' => '' }

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
    %w[bios uefi].product(['', '-noipv6']).each do |firmware, suffix|
      profiles_dir = File.expand_path('../profiles', __dir__)
      mysql = YAML.safe_load_file(File.join(profiles_dir, firmware, "mysql-2disk#{suffix}", 'user-data')).fetch('autoinstall')
      single = YAML.safe_load_file(File.join(profiles_dir, firmware, "single-disk#{suffix}", 'user-data')).fetch('autoinstall')
      assert_equal mysql.reject { |key, _| key == 'storage' },
                   single.reject { |key, _| key == 'storage' }, firmware
    end
  end

  def test_noipv6_profiles_only_add_installed_system_ipv6_configuration
    %w[bios uefi].product(%w[mysql-2disk single-disk]).each do |firmware, profile|
      directory = File.expand_path("../profiles/#{firmware}", __dir__)
      standard = YAML.safe_load_file(File.join(directory, profile, 'user-data')).fetch('autoinstall')
      noipv6 = YAML.safe_load_file(File.join(directory, "#{profile}-noipv6", 'user-data')).fetch('autoinstall')
      assert_equal standard, noipv6.reject { |key, _| key == 'late-commands' }
      command = noipv6.fetch('late-commands').join("\n")
      assert_includes command, '/target/etc/sysctl.d/99-disable-ipv6.conf'
      assert_includes command, 'net.ipv6.conf.all.disable_ipv6 = 1'
      assert_includes command, 'net.ipv6.conf.default.disable_ipv6 = 1'
    end
  end
end
