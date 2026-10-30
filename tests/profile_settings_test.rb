# frozen_string_literal: true

require 'minitest/autorun'
require 'yaml'

# Checks the installer choices shared by every NoCloud profile.
class ProfileSettingsTest < Minitest::Test
  def test_all_profiles_have_the_required_installer_choices
    profiles = Dir.glob(File.expand_path('../profiles/*/user-data', __dir__)).sort
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
end
