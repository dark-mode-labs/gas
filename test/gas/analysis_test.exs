defmodule Gas.AnalysisTest do
  use ExUnit.Case, async: true

  alias Gas.Analysis

  defp reads(source),
    do: source |> Gas.parse!() |> Map.fetch!(:parsed_template) |> Analysis.reads()

  defp targets(source),
    do: source |> Gas.parse!() |> Map.fetch!(:parsed_template) |> Analysis.render_targets()

  describe "reads/1" do
    test "reports the field a template reads, not the map holding it" do
      paths = reads("{{ context.item.name }}")

      assert MapSet.member?(paths, ["context", "item", "name"])
      refute MapSet.member?(paths, ["context", "item"])
    end

    test "reports the map itself when the template prints it whole" do
      assert MapSet.member?(reads("{{ context.item }}"), ["context", "item"])
    end

    test "stops the path at an access the template does not fix" do
      paths = reads("{{ context.item[key] }}")

      assert MapSet.member?(paths, ["context", "item"])
      assert MapSet.member?(paths, ["key"])
    end

    test "a fixed access past an unfixed one does not extend the path" do
      paths = reads("{{ context.item[key].name }}")

      assert MapSet.member?(paths, ["context", "item"])
      refute MapSet.member?(paths, ["context", "item", "name"])
    end

    test "a filter reading the map whole reports the map" do
      assert MapSet.member?(reads("{{ context.item | map: 'name' }}"), ["context", "item"])
    end

    test "a name bound to a read carries that read" do
      paths = reads("{% assign loc = context.item %}{{ loc.name }}")

      assert MapSet.member?(paths, ["context", "item"])
      assert MapSet.member?(paths, ["loc", "name"])
    end

    test "reads inside conditions, loops and filter arguments are all reported" do
      paths =
        reads("""
        {% if a.one %}{{ b.two | default: c.three }}{% endif %}
        {% for x in d.four %}{{ x.five }}{% endfor %}
        """)

      for path <- [["a", "one"], ["b", "two"], ["c", "three"], ["d", "four"], ["x", "five"]] do
        assert MapSet.member?(paths, path), "missing #{inspect(path)}"
      end
    end

    test "text alone reads nothing" do
      assert Enum.empty?(reads("just words"))
    end
  end

  describe "render_targets/1" do
    test "names a template rendered by a fixed name" do
      assert MapSet.member?(targets("{% render 'snippets/typography' %}"), "snippets/typography")
    end

    test "marks a rendered name the template builds itself" do
      source = "{% assign name = block.type %}{% render name, block: block %}"

      assert MapSet.member?(targets(source), :computed)
    end

    test "marks a rendered name whose literal carries liquid of its own" do
      targets =
        "{% render 'snippets/{{ block.type }}' %}"
        |> Gas.parse!()
        |> Gas.Compiler.Interpolation.expand([])
        |> Map.fetch!(:parsed_template)
        |> Analysis.render_targets()

      assert MapSet.member?(targets, :computed)
      refute MapSet.member?(targets, "snippets/{{ block.type }}")
    end

    test "finds a render nested in a loop" do
      source = "{% for x in a.list %}{% render 'icon' %}{% endfor %}"

      assert MapSet.member?(targets(source), "icon")
    end
  end
end
