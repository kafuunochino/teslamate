defmodule TeslaMate.Locations.AddressDisplayTest do
  use ExUnit.Case, async: true

  alias TeslaMate.Fleet
  alias TeslaMate.Locations.{Address, GeoFence}

  test "retains Chinese street and landmark detail in province-to-street order" do
    address = %Address{
      name: "测试区",
      city: "测试区",
      display_name: "测试公园, 测试路, 测试街道, 测试区, 测试市, 测试省, 550000, 中国"
    }

    assert Fleet.address_label(address) ==
             "测试省 · 测试市 · 测试区 · 测试街道 · 测试路 · 测试公园"
  end

  test "falls back to structured street and house number when display name is absent" do
    address = %Address{
      display_name: " ",
      name: "测试园",
      road: "测试路",
      house_number: "18号",
      city: "测试市",
      country: "中国"
    }

    assert Address.display_label(address) == "测试市 · 测试路 18号 · 测试园"
  end

  test "preserves international order and user-defined geofence names" do
    assert Address.format_display_name("Building, 1 Main Street, London, United Kingdom") ==
             "Building · 1 Main Street · London · United Kingdom"

    assert Fleet.address_label(%GeoFence{name: "Home, China"}) == "Home, China"
  end

  test "missing or duplicate fragments do not produce broken separators" do
    assert Address.display_label(%Address{}) == "未知位置"
    assert Address.format_display_name("Unknown") == "未知位置"
    assert Address.format_display_name("街道，，区，区，中国") == "区 · 街道"
  end
end
