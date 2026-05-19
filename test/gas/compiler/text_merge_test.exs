defmodule Gas.Compiler.TextMergeTest do
  use ExUnit.Case, async: true

  alias Gas.Compiler.TextMerge
  alias Gas.{Template, Text}

  defp template(nodes), do: %Template{parsed_template: nodes}
  defp text(t), do: %Text{loc: nil, text: t}

  test "merges two adjacent Text nodes into one" do
    result = TextMerge.run(template([text("a"), text("b")]))
    assert result.parsed_template == [%Text{loc: nil, text: "ab"}]
  end

  test "merges three or more adjacent Text nodes" do
    result = TextMerge.run(template([text("a"), text("b"), text("c")]))
    assert result.parsed_template == [%Text{loc: nil, text: "abc"}]
  end

  test "leaves a single Text node unchanged" do
    nodes = [text("solo")]
    assert TextMerge.run(template(nodes)).parsed_template == nodes
  end

  test "does not merge Text across an Object" do
    {:ok, parsed} = Gas.parse("hi {{ name }} there")
    result = TextMerge.run(parsed)

    assert [%Text{}, %Gas.Object{}, %Text{}] = result.parsed_template
  end

  test "preserves the first Text's loc when merging" do
    a = %Text{loc: %Gas.Parser.Loc{line: 1, column: 1}, text: "a"}
    b = %Text{loc: %Gas.Parser.Loc{line: 1, column: 2}, text: "b"}

    [merged] = TextMerge.run(template([a, b])).parsed_template
    assert merged.text == "ab"
    assert merged.loc == a.loc
  end

  test "recurses into tag bodies" do
    {:ok, parsed} = Gas.parse("{% if x %}aa{% endif %}")
    [%Gas.Tags.IfTag{body: body}] = parsed.parsed_template

    # `aa` is parsed as one Text already in this case; verify that running
    # text-merge over the body doesn't damage non-mergeable lists.
    result = TextMerge.run(parsed)
    [%Gas.Tags.IfTag{body: merged_body}] = result.parsed_template
    assert length(body) == length(merged_body)
  end

  test "returns an empty list unchanged" do
    assert TextMerge.run(template([])).parsed_template == []
  end
end
