defmodule Gas.AssetFilterTest do
  use ExUnit.Case, async: false
  import Gas.Helpers

  defmodule ProxyResolver do
    @moduledoc false
    def fetch_url(uuid), do: "https://cdn.test/#{uuid}.png"
    def fetch_url(uuid, %{width: width}), do: "https://img.test/#{width}x/#{fetch_url(uuid)}"
    def fetch_url(uuid, _opts), do: fetch_url(uuid)
  end

  defmodule LegacyResolver do
    @moduledoc false
    def fetch_url(uuid), do: "https://cdn.test/#{uuid}.png"
  end

  @uuid "0f9ca6a0-3f18-4c1d-9f2e-6bd9d1a5a111"
  @resolved "https://cdn.test/#{@uuid}.png"

  defp configure(resolver) do
    Application.put_env(:gas, :asset_resolver, resolver)
    on_exit(fn -> Application.delete_env(:gas, :asset_resolver) end)
  end

  describe "image_url width" do
    setup do
      configure(ProxyResolver)
    end

    test "reaches the resolver" do
      assert render("{{ favicon | image_url: width: 300 }}", %{"favicon" => @uuid}) ==
               "https://img.test/300x/#{@resolved}"
    end

    test "reaches the resolver when given as a string" do
      assert render("{{ favicon | image_url: width: width }}", %{
               "favicon" => @uuid,
               "width" => "300"
             }) == "https://img.test/300x/#{@resolved}"
    end

    test "reaches the resolver when given as a float" do
      assert render("{{ favicon | image_url: width: 300.0 }}", %{"favicon" => @uuid}) ==
               "https://img.test/300x/#{@resolved}"
    end

    test "reaches the resolver for the first asset of a list" do
      assert render("{{ favicons | image_url: width: 300 }}", %{"favicons" => [@uuid]}) ==
               "https://img.test/300x/#{@resolved}"
    end

    test "is passed alongside other options" do
      assert render("{{ favicon | image_url: width: 32, height: 32 }}", %{"favicon" => @uuid}) ==
               "https://img.test/32x/#{@resolved}"
    end

    test "is omitted when absent" do
      assert render("{{ favicon | image_url: height: 32 }}", %{"favicon" => @uuid}) == @resolved
    end

    test "is omitted when not a positive number" do
      assert render("{{ favicon | image_url: width: 0 }}", %{"favicon" => @uuid}) == @resolved

      assert render("{{ favicon | image_url: width: 'wide' }}", %{"favicon" => @uuid}) ==
               @resolved
    end

    test "is omitted when the filter is given a positional argument" do
      assert render("{{ favicon | image_url: 300 }}", %{"favicon" => @uuid}) == @resolved
    end

    test "is ignored for an asset that is already a url" do
      assert render(~s({{ "https://example.com/a.png" | image_url: width: 300 }})) ==
               "https://example.com/a.png"
    end
  end

  describe "image_url resolver" do
    test "falls back to fetch_url/1 when the resolver does not take options" do
      configure(LegacyResolver)

      assert render("{{ favicon | image_url: width: 300 }}", %{"favicon" => @uuid}) == @resolved
    end

    test "leaves the asset untouched when unconfigured" do
      Application.delete_env(:gas, :asset_resolver)

      assert render("{{ favicon | image_url: width: 300 }}", %{"favicon" => @uuid}) == @uuid
    end
  end
end
