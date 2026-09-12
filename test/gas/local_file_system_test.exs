defmodule Gas.LocalFileSystemTest do
  use ExUnit.Case, async: true

  alias Gas.LocalFileSystem

  setup do
    base = Path.join(System.tmp_dir!(), "gas-fs-#{System.unique_integer([:positive])}")
    one = Path.join(base, "one")
    two = Path.join(base, "two")
    File.mkdir_p!(Path.join(one, "snippets"))
    File.mkdir_p!(Path.join(two, "snippets"))
    on_exit(fn -> File.rm_rf!(base) end)

    %{one: one, two: two}
  end

  defp write(root, name, content),
    do: File.write!(Path.join(root, name <> ".liquid"), content)

  test "a name is read from whichever root holds it", %{one: one, two: two} do
    write(one, "snippets/only-in-one", "ONE")
    write(two, "snippets/only-in-two", "TWO")

    fs = LocalFileSystem.new([one, two], "%s.liquid")

    assert LocalFileSystem.read_template_file("snippets/only-in-one", fs) == {:ok, "ONE"}
    assert LocalFileSystem.read_template_file("snippets/only-in-two", fs) == {:ok, "TWO"}
  end

  test "the first root holding a name wins", %{one: one, two: two} do
    write(one, "snippets/shared", "FIRST")
    write(two, "snippets/shared", "SECOND")

    fs = LocalFileSystem.new([one, two], "%s.liquid")
    assert LocalFileSystem.read_template_file("snippets/shared", fs) == {:ok, "FIRST"}

    flipped = LocalFileSystem.new([two, one], "%s.liquid")
    assert LocalFileSystem.read_template_file("snippets/shared", flipped) == {:ok, "SECOND"}
  end

  test "a name no root holds is an error naming it", %{one: one, two: two} do
    fs = LocalFileSystem.new([one, two], "%s.liquid")

    assert {:error, %Gas.FileSystem.Error{reason: reason}} =
             LocalFileSystem.read_template_file("snippets/absent", fs)

    assert reason == "No such template 'snippets/absent'"
  end

  test "a single root may still be given as a bare path", %{one: one} do
    write(one, "snippets/solo", "SOLO")

    fs = LocalFileSystem.new(one, "%s.liquid")
    assert LocalFileSystem.read_template_file("snippets/solo", fs) == {:ok, "SOLO"}
  end

  test "a template in one root renders one in another", %{one: one, two: two} do
    write(one, "snippets/caller", "[{% render 'snippets/callee' %}]")
    write(two, "snippets/callee", "reached")

    opts = [file_system: {LocalFileSystem, LocalFileSystem.new([one, two], "%s.liquid")}]

    assert {:ok, template} = Gas.precompile("snippets/caller", opts)
    assert {:ok, out, []} = Gas.render(template, %Gas.Context{}, opts)
    assert IO.iodata_to_binary(out) == "[reached]"
  end

  test "an illegal name is refused before any root is read", %{one: one, two: two} do
    fs = LocalFileSystem.new([one, two], "%s.liquid")

    assert {:error, %Gas.FileSystem.Error{reason: reason}} =
             LocalFileSystem.read_template_file("../etc/passwd", fs)

    assert reason =~ "Illegal template name"
  end
end
