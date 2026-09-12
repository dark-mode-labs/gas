defmodule Gas.AssetFilterTest do
  use ExUnit.Case, async: false
  import Gas.Helpers

  @versions ~w(1 2 3 4 5 6 7 8)
  @uuid "0f9ca6a0-3f18-4c1d-9f2e-6bd9d1a5a111"
  @uuid_v7 "019fd8e1-3637-7f7d-836f-71d9d29a99a6"
  @resolved "https://cdn.test/#{@uuid}.png"

  defmodule ProxyResolver do
    @moduledoc false
    @known [
      "0f9ca6a0-3f18-4c1d-9f2e-6bd9d1a5a111"
      | Enum.map(~w(1 2 3 4 5 6 7 8), &"019fd8e1-3637-#{&1}f7d-836f-71d9d29a99a6")
    ]

    def fetch_url(uuid) when uuid in @known, do: "https://cdn.test/#{uuid}.png"
    def fetch_url(_uuid), do: nil

    def fetch_url(uuid, %{width: width}) do
      case fetch_url(uuid) do
        nil -> nil
        url -> "https://img.test/#{width}x/#{url}"
      end
    end

    def fetch_url(uuid, _opts), do: fetch_url(uuid)
  end

  defmodule LegacyResolver do
    @moduledoc false
    def fetch_url("0f9ca6a0-3f18-4c1d-9f2e-6bd9d1a5a111" = uuid),
      do: "https://cdn.test/#{uuid}.png"

    def fetch_url(_uuid), do: nil
  end

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
  end

  describe "image_url identifier format" do
    setup do
      configure(ProxyResolver)
    end

    test "resolves a v7 identifier" do
      assert render("{{ favicon | image_url: height: 32 }}", %{"favicon" => @uuid_v7}) ==
               "https://cdn.test/#{@uuid_v7}.png"
    end

    test "resolves an identifier of every uuid version" do
      for v <- @versions do
        uuid = "019fd8e1-3637-#{v}f7d-836f-71d9d29a99a6"

        assert render("{{ favicon | image_url: height: 32 }}", %{"favicon" => uuid}) ==
                 "https://cdn.test/#{uuid}.png"
      end
    end

    test "passes through a value the resolver declines" do
      assert render(~s({{ "https://example.com/a.png" | image_url: width: 300 }})) ==
               "https://example.com/a.png"

      assert render("{{ favicon | image_url: width: 300 }}", %{"favicon" => "hero-banner1.jpg"}) ==
               "hero-banner1.jpg"
    end
  end

  # An inline SVG is written with spaces, which `URI.new/1` rejects and the image was dropped.
  describe "image_url on a data URI" do
    setup do
      configure(ProxyResolver)
    end

    @svg "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='56'%3E%3C/svg%3E"

    test "hands back an inline SVG unchanged, spaces and all" do
      assert render("{{ logo | image_url: width: 300 }}", %{"logo" => @svg}) == @svg
    end

    test "hands it back whatever sizing was asked for, since there is nothing to resize" do
      assert render("{{ logo | image_url: height: 32 }}", %{"logo" => @svg}) == @svg
    end

    test "hands back a data URI that needs no encoding" do
      encoded = String.replace(@svg, " ", "%20")
      assert render("{{ logo | image_url: width: 300 }}", %{"logo" => encoded}) == encoded
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
