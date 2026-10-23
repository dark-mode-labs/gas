defmodule Gas.DateFilterTest do
  use ExUnit.Case, async: true
  alias Gas.StandardFilter

  @loc %Gas.Parser.Loc{line: 1, column: 1}

  defp date(args), do: StandardFilter.apply("date", args, @loc, [])

  test "a calendar date formats as that day" do
    assert date(["2026-10-23", "%A, %b %-d"]) == {:ok, "Friday, Oct 23"}
  end

  test "a datetime with no offset formats rather than passing through" do
    assert date(["2026-10-23T20:30:00", "%H:%M"]) == {:ok, "20:30"}
  end

  test "a datetime with an offset still formats" do
    assert date(["2000-01-01 00:00:00Z", "%a, %b %d, %y"]) == {:ok, "Sat, Jan 01, 00"}
  end

  test "what cannot be read as a date comes back unchanged" do
    assert date(["invalid-date", "%Y"]) == {:ok, "invalid-date"}
  end
end
