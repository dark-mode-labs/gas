defmodule Gas.TelFilterTest do
  use ExUnit.Case, async: false
  import Gas.Helpers
  alias Gas.StandardFilter

  @loc %Gas.Parser.Loc{line: 1, column: 1}

  defp tel(args), do: StandardFilter.apply("tel", args, @loc, [])

  describe "tel filter" do
    test "formats national numbers with the default country code" do
      assert tel(["(555) 123-4567"]) == {:ok, "+15551234567"}
      assert tel(["555-123-4567"]) == {:ok, "+15551234567"}
      assert tel([" 555.123.4567 "]) == {:ok, "+15551234567"}
      assert tel(["5551234567"]) == {:ok, "+15551234567"}
    end

    test "keeps a number that already carries a country code" do
      assert tel(["+1 (555) 123-4567"]) == {:ok, "+15551234567"}
      assert tel(["1-555-123-4567"]) == {:ok, "+15551234567"}
      assert tel(["+15551234567"]) == {:ok, "+15551234567"}
    end

    test "treats a 00 prefix as international" do
      assert tel(["0044 20 7183 8750"]) == {:ok, "+442071838750"}
    end

    test "drops the national trunk prefix when applying a country code" do
      assert tel(["020 7183 8750", "44"]) == {:ok, "+442071838750"}
    end

    test "accepts the country code with a plus or as an integer" do
      assert tel(["020 7183 8750", "+44"]) == {:ok, "+442071838750"}
      assert tel(["020 7183 8750", 44]) == {:ok, "+442071838750"}
    end

    test "falls back to the configured default country code" do
      Application.put_env(:gas, :default_country_code, "44")
      on_exit(fn -> Application.delete_env(:gas, :default_country_code) end)

      assert tel(["020 7183 8750"]) == {:ok, "+442071838750"}
    end

    test "formats international input even when no country code resolves" do
      Application.put_env(:gas, :default_country_code, "")
      on_exit(fn -> Application.delete_env(:gas, :default_country_code) end)

      assert tel(["+1 (555) 123-4567"]) == {:ok, "+15551234567"}
      assert tel(["555-123-4567"]) == {:ok, "555-123-4567"}
    end

    test "renders with the empty literal as country code" do
      assert render("{{ phone | tel: empty }}", %{"phone" => "(555) 123-4567"}) ==
               "+15551234567"
    end

    test "returns input unchanged when it cannot be normalized" do
      assert tel(["not a phone"]) == {:ok, "not a phone"}
      assert tel(["555-1234567890123456"]) == {:ok, "555-1234567890123456"}
      assert tel([""]) == {:ok, ""}
      assert tel([nil]) == {:ok, nil}
    end

    test "formats an integer input" do
      assert tel([5_551_234_567]) == {:ok, "+15551234567"}
    end

    test "renders inside a tel link" do
      assert render(~s(<a href="tel:{{ phone | tel }}">call</a>), %{
               "phone" => "(555) 123-4567"
             }) == ~s(<a href="tel:+15551234567">call</a>)
    end

    test "renders with a country code argument" do
      assert render("{{ phone | tel: '44' }}", %{"phone" => "020 7183 8750"}) ==
               "+442071838750"
    end
  end
end
