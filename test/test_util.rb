# frozen_string_literal: true

require_relative "helper"

require "puma/util"

class TestUtilHeaderHash < PumaTest
  parallelize_me!

  def test_merge_does_not_share_name_index_with_receiver
    hh = Puma::Util::HeaderHash.new("Content-Length" => "5")
    merged = hh.merge("content-length" => "7", "X-New" => "1")

    assert_equal({"content-length" => "7", "X-New" => "1"}, merged.to_hash)
    assert_equal "5", hh["content-length"]
    refute hh.include?("X-New")

    hh["Content-Length"] = "9"
    assert_equal({"Content-Length" => "9"}, hh.to_hash)
  end

  def test_dup_does_not_share_name_index_with_receiver
    hh = Puma::Util::HeaderHash.new("A" => "1")
    copy = hh.dup
    copy["a"] = "2"

    assert_equal({"A" => "1"}, hh.to_hash)
    assert_equal "1", hh["a"]
    assert_equal({"a" => "2"}, copy.to_hash)
  end
end
