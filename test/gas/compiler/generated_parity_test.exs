defmodule Gas.Compiler.GeneratedParityTest do
  @moduledoc """
  Liquid built from a grammar, rendered compiled and interpreted, byte for byte.

  This is for finding bugs, not for holding the line on found ones: every bug it
  turned up has a named test of its own beside it, because a random walk covers
  any particular combination only by luck — widening the grammar was measured to
  push known bugs back out of reach as often as it pulled new ones in.

  What it is good at is the product of features, which is where the bugs were:
  each was a pair meeting — a deferred assign under a path read, a loop variable
  over a folded name — and each rendered correctly alone.

  Seeded, so a failure names the seed that produced it and can be replayed. Raise
  the range for a deeper search; 3000 is clean at the time of writing.
  """

  use ExUnit.Case, async: true

  alias Gas.Compiler.Codegen

  defmodule Snippets do
    @behaviour Gas.FileSystem

    # Isolated by `{% render %}`, so each reads only what it was handed — including a name the
    # caller was still holding when it called.
    @impl true
    def read_template_file("plain", _opts), do: {:ok, "<s>{{ arg }}</s>"}

    def read_template_file("assigning", _opts),
      do: {:ok, "{% assign arg = 'in' %}<s>{{ arg }}</s>"}

    def read_template_file("looping", _opts),
      do: {:ok, "{% for q in arg %}<s>{{ q }}</s>{% endfor %}"}

    def read_template_file("counting", _opts), do: {:ok, "{% increment n %}<s>{{ arg }}</s>"}
  end

  @opts [
    module_limit: 1_000_000,
    opaque_roots: ~w(block settings s),
    file_system: {Snippets, nil}
  ]

  # Values a host actually hands over: maps to walk into, lists to loop, and a setting holding
  # liquid, which resolves against the context reading it rather than against what is in hand.
  # Values nothing compares against stay varied, so the falsy and blank branches are walked. The
  # ones a divergence shows up in are held: empty on both sides proves nothing, and varying them
  # was measured to make this test miss five of the six bugs it exists for.
  @varied [nil, "", 0, false, [], "lg", 3, true, ~w(a b)]

  defp vars do
    pick = fn -> Enum.random(@varied) end

    %{
      "src" => %{"y" => "Y", "z" => %{"deep" => "D"}, "n" => pick.()},
      "xs" => Enum.random([~w(a b c), ~w(a b c), ["only"], [nil, "b"]]),
      "ys" => Enum.random([~w(1 2), ~w(1 2), ["x"]]),
      "who" => "ada",
      "flag" => pick.(),
      "off" => false,
      "empty" => [],
      "num" => 2,
      "block" => %{
        "settings" => %{"tpl" => "{{ who }}/{{ acc }}", "size" => pick.(), "on" => pick.()}
      },
      "s" => %{"role" => "surface", "pad" => pick.()}
    }
  end

  @reads [
    "who",
    "src.y",
    "src.z.deep",
    "acc",
    "block.settings.size",
    "s.role",
    "src[key]",
    "block.settings.tpl",
    "obj.y",
    "obj.z.deep",
    "obj[key]"
  ]

  @filters ["", " | upcase", " | append: '!'", " | default: 'dflt'", " | size", " | strip"]

  defp read, do: Enum.random(@reads)
  defp filter, do: Enum.random(@filters)

  @writes ~w(assign assign_read assign_run assign_map assign_opaque capture capture_const)a
  @blocks ~w(if unless case for nested_for tablerow)a

  defp statement(depth) do
    # Weighted, not uniform: every bug this has caught was an assign or a capture meeting
    # something else, and spreading the draw evenly over fourteen shapes made those pairs rare
    # enough that the walk stopped finding them.
    shape = Enum.random(choices(depth))

    cond do
      shape in @writes -> writes(shape, depth)
      shape in @blocks -> blocks(shape, depth)
      true -> calls(shape, depth)
    end
  end

  defp choices(depth) when depth <= 0,
    do: [:output, :render, :render_list, :counter] ++ @writes ++ @writes

  defp choices(_depth),
    do:
      [:output, :render, :render_list, :render_for, :cycle, :counter] ++
        @writes ++ @writes ++ @blocks

  defp writes(shape, depth) do
    case shape do
      :assign ->
        "{% assign acc = '#{Enum.random(~w(p q r))}'#{filter()} %}"

      :assign_read ->
        "{% assign acc = #{read()}#{filter()} %}"

      # The target holds a map, so the read that follows walks through a name whose write may
      # still be waiting; a bare read of it would resolve to the variable instead.
      :assign_run ->
        "{% assign acc = '#{Enum.random(~w(p q r))}' %}" <>
          "{% assign acc = #{read()}#{filter()} %}" <>
          "{% assign acc = acc#{filter()} %}"

      # A setting holding liquid read through a filter, so the assign holds the rendered value
      # rather than standing in for the setting. Spelled out: the walk kept missing it.
      :assign_map ->
        "{% assign obj = #{Enum.random(~w(src obj block.settings))} %}" <>
          "{% assign acc = #{Enum.random(~w(obj.y obj.z.deep obj[key]))}#{filter()} %}"

      # Assigns back to back, which is what the deferred context write has to wait across.
      :assign_opaque ->
        "{% assign acc = '#{Enum.random(~w(p q r))}' %}" <>
          "{% assign out = block.settings.tpl#{Enum.random([" | append: ''", " | upcase"])} %}" <>
          "<o>{{ out }}</o>"

      :capture ->
        "{% capture acc %}#{body(depth - 1)}{% endcapture %}"

      # A captured body the bindings settle folds to a string, which is a different path through
      # the compiler than one it has to run.
      :capture_const ->
        "{% capture acc %}#{Enum.random(~w(lit fixed const))}{% endcapture %}"
    end
  end

  defp blocks(shape, depth) do
    case shape do
      :if ->
        "{% if #{read()} %}#{body(depth - 1)}" <>
          "{% else %}#{body(depth - 1)}{% endif %}"

      :unless ->
        "{% unless #{read()} %}#{body(depth - 1)}{% endunless %}"

      :case ->
        "{% case #{read()} %}{% when 'Y' %}#{body(depth - 1)}" <>
          "{% else %}#{body(depth - 1)}{% endcase %}"

      :for ->
        v = Enum.random(~w(i acc key))

        "{% for #{v} in #{Enum.random(~w(xs ys empty))} %}#{body(depth - 1)}{% endfor %}"

      :nested_for ->
        "{% for i in xs %}{% for acc in ys %}#{body(depth - 1)}{% endfor %}{% endfor %}"

      :tablerow ->
        "{% tablerow t in #{Enum.random(~w(xs ys))} %}#{body(depth - 1)}{% endtablerow %}"
    end
  end

  defp calls(shape, _depth) do
    case shape do
      :render -> "{% render '#{Enum.random(~w(plain assigning counting))}', arg: #{read()} %}"
      :render_list -> "{% render 'looping', arg: #{Enum.random(~w(xs ys obj.z))} %}"
      :render_for -> "{% render 'plain' for #{Enum.random(~w(xs ys))} as arg %}"
      :counter -> "{% #{Enum.random(~w(increment decrement))} #{Enum.random(~w(acc n key))} %}"
      :cycle -> "{% for i in xs %}{% cycle 'a', 'b' %}{% endfor %}"
      :output -> "{{ #{read()}#{filter()} }}"
    end
  end

  # Literal text between statements, so the comparison is over real output and not two blanks.
  defp body(depth) do
    Enum.map_join(1..Enum.random(1..3)//1, "", fn _ ->
      "<i>#{Enum.random(~w(alpha beta gamma))}</i>" <> statement(depth)
    end)
  end

  # Seeded per template, so a failing seed replays exactly.
  defp template(seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 2})
    # `key` is bound up front so a bracket read has something to resolve.
    "{% assign key = 'y' %}{% assign acc = 'seed' %}{% assign obj = src %}" <> body(3)
  end

  defp outcome(fun) do
    {io, _ctx} = fun.()
    {:ok, IO.iodata_to_binary(io)}
  rescue
    error -> {:raised, Exception.message(error)}
  end

  test "generated liquid renders identically compiled and interpreted" do
    # The grammar is the coverage, so what it actually emitted is counted rather than assumed.
    tags = ~w(render tablerow increment decrement cycle capture assign for case unless if)

    {mismatches, rendered, skipped, shapes, substantial} =
      for seed <- 1..400, reduce: {[], 0, 0, Map.new(tags, &{&1, 0}), 0} do
        {acc, bytes, short, seen, big} ->
          source = template(seed)
          context = %Gas.Context{vars: Gas.Compiler.Interpolation.normalize_vars(vars(), @opts)}

          seen =
            Enum.reduce(tags, seen, fn tag, counts ->
              if String.contains?(source, "{% " <> tag),
                do: Map.update!(counts, tag, &(&1 + 1)),
                else: counts
            end)

          case Gas.parse(source, @opts) do
            {:ok, parsed} ->
              {:ok, module} = Codegen.ensure_compiled(parsed.parsed_template, %{}, @opts)

              interpreted = outcome(fn -> Gas.render(parsed.parsed_template, context, @opts) end)
              compiled = outcome(fn -> module.render(context, @opts) end)

              {grown, big} =
                case compiled do
                  {:ok, out} ->
                    {bytes + byte_size(out), if(byte_size(out) > 40, do: big + 1, else: big)}

                  _other ->
                    {bytes, big}
                end

              if compiled == interpreted,
                do: {acc, grown, short, seen, big},
                else: {[{seed, source, interpreted, compiled} | acc], grown, short, seen, big}

            {:error, _reason} ->
              {acc, bytes, short + 1, seen, big}
          end
      end

    assert skipped == 0, "#{skipped} generated templates did not parse; the grammar is wrong"

    thin = Enum.reject(shapes, fn {_tag, seen} -> seen > 20 end)

    assert thin == [],
           "these shapes barely appear, so the walk does not cover them: " <>
             Enum.map_join(thin, ", ", fn {tag, seen} -> "#{tag} in #{seen}/400" end)

    # The values include nil and empty on purpose, so a template may render little; what must not
    # happen is most of them rendering nothing at all.
    assert rendered > 20_000, "only #{rendered} bytes over 400 templates; the walk is vacuous"

    # Well under what the grammar produces, so this catches a collapse rather than pinning a
    # number the grammar is free to move.
    assert substantial > 100,
           "only #{substantial}/400 templates rendered more than a few bytes"

    assert mismatches == [],
           Enum.map_join(Enum.take(mismatches, 5), "\n\n", fn {seed, source, i, c} ->
             "seed #{seed}\n  #{source}\n  interpreted: #{inspect(i)}\n  compiled:    #{inspect(c)}"
           end)
  end
end
