defmodule Gas.TimeAgoFilterTest do
  use ExUnit.Case, async: true
  import Gas.Helpers
  alias Gas.StandardFilter

  @loc %Gas.Parser.Loc{line: 1, column: 1}

  defp time_ago(args), do: StandardFilter.apply("time_ago", args, @loc, [])
  defp relative_time(args), do: StandardFilter.apply("relative_time", args, @loc, [])

  defp seconds_ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)
  defp seconds_from_now(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  describe "time_ago filter" do
    test "counts back in the largest whole unit" do
      assert time_ago([seconds_ago(300)]) == {:ok, "5 minutes ago"}
      assert time_ago([seconds_ago(3 * 3600)]) == {:ok, "3 hours ago"}
      assert time_ago([seconds_ago(3 * 86_400)]) == {:ok, "3 days ago"}
      assert time_ago([seconds_ago(21 * 86_400)]) == {:ok, "3 weeks ago"}
      assert time_ago([seconds_ago(200 * 86_400)]) == {:ok, "6 months ago"}
      assert time_ago([seconds_ago(800 * 86_400)]) == {:ok, "2 years ago"}
    end

    test "drops the partial unit rather than rounding it" do
      assert time_ago([seconds_ago(3 * 3600 + 1800)]) == {:ok, "3 hours ago"}
      assert time_ago([seconds_ago(6 * 86_400 + 82_800)]) == {:ok, "6 days ago"}
    end

    test "drops the plural for a single unit" do
      assert time_ago([seconds_ago(90)]) == {:ok, "1 minute ago"}
      assert time_ago([seconds_ago(90 * 60)]) == {:ok, "1 hour ago"}
      assert time_ago([seconds_ago(26 * 3600)]) == {:ok, "1 day ago"}
      assert time_ago([seconds_ago(10 * 86_400)]) == {:ok, "1 week ago"}
      assert time_ago([seconds_ago(40 * 86_400)]) == {:ok, "1 month ago"}
      assert time_ago([seconds_ago(400 * 86_400)]) == {:ok, "1 year ago"}
    end

    test "never runs forward, whatever the datetime" do
      assert time_ago([seconds_from_now(90)]) == {:ok, "just now"}
      assert time_ago([seconds_from_now(2 * 86_400)]) == {:ok, "just now"}
      assert time_ago([seconds_from_now(800 * 86_400)]) == {:ok, "just now"}
    end

    test "reads anything inside a minute either way as just now" do
      assert time_ago([seconds_ago(59)]) == {:ok, "just now"}
      assert time_ago([seconds_ago(0)]) == {:ok, "just now"}
      assert time_ago([seconds_from_now(30)]) == {:ok, "just now"}
      assert time_ago([seconds_ago(60)]) == {:ok, "1 minute ago"}
    end

    test "accepts a naive datetime as UTC" do
      naive = NaiveDateTime.add(NaiveDateTime.utc_now(), -2 * 3600, :second)

      assert time_ago([naive]) == {:ok, "2 hours ago"}
    end

    test "accepts a date as midnight UTC" do
      assert time_ago([Date.add(Date.utc_today(), -40)]) == {:ok, "1 month ago"}
    end

    test "accepts a unix timestamp" do
      assert time_ago([DateTime.to_unix(seconds_ago(3600))]) == {:ok, "1 hour ago"}
    end

    test "accepts now and today" do
      assert time_ago(["now"]) == {:ok, "just now"}
      assert time_ago(["today"]) == {:ok, "just now"}
    end

    test "accepts an iso8601 string carrying an offset" do
      assert time_ago([DateTime.to_iso8601(seconds_ago(3 * 3600))]) == {:ok, "3 hours ago"}

      shifted = DateTime.to_iso8601(seconds_ago(3 * 3600), :extended, 19_800)

      assert time_ago([shifted]) == {:ok, "3 hours ago"}
    end

    test "accepts an iso8601 string without an offset as UTC" do
      naive = NaiveDateTime.add(NaiveDateTime.utc_now(), -3 * 3600, :second)

      assert time_ago([NaiveDateTime.to_iso8601(naive)]) == {:ok, "3 hours ago"}
    end

    test "accepts a date-only string as midnight UTC" do
      date = Date.add(Date.utc_today(), -40)

      assert time_ago([Date.to_iso8601(date)]) == {:ok, "1 month ago"}
    end

    test "returns input unchanged when it cannot be read as a datetime" do
      assert time_ago(["not a date"]) == {:ok, "not a date"}
      assert time_ago(["2024-13-45"]) == {:ok, "2024-13-45"}
      assert time_ago([""]) == {:ok, ""}
      assert time_ago([nil]) == {:ok, nil}

      assert time_ago([%{"published_at" => "yesterday"}]) ==
               {:ok, %{"published_at" => "yesterday"}}
    end

    test "renders from a context decoded out of json" do
      published_at = seconds_ago(3 * 3600) |> DateTime.to_iso8601()
      context = JSON.decode!(~s({"article": {"published_at": "#{published_at}"}}))

      assert render("{{ article.published_at | time_ago }}", context) == "3 hours ago"
    end

    test "renders inside markup" do
      published_at = DateTime.to_iso8601(seconds_ago(2 * 86_400))

      assert render(~s(<time datetime="{{ at }}">{{ at | time_ago }}</time>), %{
               "at" => published_at
             }) == ~s(<time datetime="#{published_at}">2 days ago</time>)
    end

    test "renders the empty literal as nothing" do
      assert render("{{ empty | time_ago }}") == ""
    end

    test "chains onto a filter that yields a datetime string" do
      published_at = DateTime.to_iso8601(seconds_ago(5 * 86_400))

      assert render("{{ at | default: published_at | time_ago }}", %{
               "published_at" => published_at
             }) == "5 days ago"
    end
  end

  describe "relative_time filter" do
    test "phrases a datetime in the future as in" do
      assert relative_time([seconds_from_now(90)]) == {:ok, "in 1 minute"}
      assert relative_time([seconds_from_now(2 * 86_400)]) == {:ok, "in 2 days"}
      assert relative_time([seconds_from_now(200 * 86_400)]) == {:ok, "in 6 months"}
    end

    test "reads the same scale backwards as time_ago" do
      for seconds <- [300, 90 * 60, 26 * 3600, 10 * 86_400, 200 * 86_400, 800 * 86_400] do
        at = seconds_ago(seconds)

        assert relative_time([at]) == time_ago([at])
      end
    end

    test "accepts the same input shapes" do
      assert relative_time([DateTime.to_iso8601(seconds_from_now(3 * 3600 + 1800))]) ==
               {:ok, "in 3 hours"}

      assert relative_time([DateTime.to_unix(seconds_from_now(3 * 3600 + 1800))]) ==
               {:ok, "in 3 hours"}

      assert relative_time([NaiveDateTime.utc_now()]) == {:ok, "just now"}
      assert relative_time(["not a date"]) == {:ok, "not a date"}
      assert relative_time([nil]) == {:ok, nil}
    end

    test "renders a future datetime in a template" do
      assert render("{{ ships_at | relative_time }}", %{
               "ships_at" => DateTime.to_iso8601(seconds_from_now(2 * 86_400))
             }) == "in 2 days"
    end
  end
end
