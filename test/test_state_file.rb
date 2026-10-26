# frozen_string_literal: true

require_relative "helper"
require_relative "helpers/tmp_path"

require 'puma/state_file'

class TestStateFile < PumaTest
  include TmpPath

  def test_load_empty_value_as_nil
    state_path = tmp_path('.state')
    File.write state_path, <<-STATE
---
pid: 123456
control_url:
control_auth_token:
running_from: "/path/to/app"
    STATE

    sf = Puma::StateFile.new
    sf.load(state_path)
    assert_equal 123456, sf.pid
    assert_equal '/path/to/app', sf.running_from
    assert_nil sf.control_url
    assert_nil sf.control_auth_token

  end

  def test_numeric_looking_string_values_round_trip_as_strings
    state_path = tmp_path('.state')
    sf = Puma::StateFile.new
    sf.pid = 123456
    sf.control_url = 'tcp://127.0.0.1:9293'
    sf.control_auth_token = '0123'
    sf.save state_path

    loaded = Puma::StateFile.new
    loaded.load state_path
    assert_equal 123456, loaded.pid
    assert_equal 'tcp://127.0.0.1:9293', loaded.control_url
    assert_equal '0123', loaded.control_auth_token
  end

  def test_load_keeps_string_fields_as_strings
    state_path = tmp_path('.state')
    File.write state_path, "---\npid: 123456\ncontrol_auth_token: 0123\nrunning_from: 42\n"

    sf = Puma::StateFile.new
    sf.load state_path
    assert_equal 123456, sf.pid
    assert_equal '0123', sf.control_auth_token
    assert_equal '42', sf.running_from
  end
end
