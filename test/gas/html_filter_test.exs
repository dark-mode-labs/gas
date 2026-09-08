defmodule Gas.HTMLFilterTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Gas.Helpers

  alias Gas.Compiler.Codegen

  # The module-level rescue would satisfy a parity assert by falling back, so check the log.
  defp both(source, vars) do
    {:ok, template} = Gas.parse(source)
    mod = Module.concat([Gas.HTMLFilterCase, "M#{System.unique_integer([:positive])}"])
    {:ok, compiled} = Codegen.compile(template.parsed_template, mod)

    {out, log} =
      with_log(fn ->
        {out, _ctx} = compiled.render(%Gas.Context{vars: vars}, [])
        IO.iodata_to_binary(out)
      end)

    refute log =~ "renders interpreted from here",
           "the compiled form fell back to the interpreter"

    assert out == render(source, vars)
    out
  end

  describe "preload_tag" do
    test "renders a preload link for a url" do
      assert both("{{ url | preload_tag: as: 'style' }}", %{"url" => "/a.css"}) ==
               ~s(<link rel="preload" href="/a.css" as="style">)
    end

    test "an unset url renders nothing rather than raising" do
      assert both("{{ url | preload_tag: as: 'style' }}", %{}) == ""
    end
  end

  describe "stylesheet_tag" do
    test "renders a stylesheet link for a url" do
      assert both("{{ url | stylesheet_tag }}", %{"url" => "/a.css"}) ==
               ~s(<link rel="stylesheet" href="/a.css" media="all">)
    end

    test "an unset url renders nothing rather than raising" do
      assert both("{{ url | stylesheet_tag }}", %{}) == ""
    end
  end
end
