import
  nimtest,
  tray/menutree

describe "dbusmenu labels":

  it "strips mnemonics":
    assert stripMnemonics("_File") == "File"
    assert stripMnemonics("Save _as...") == "Save as..."

  it "turns doubled underscores into one":
    assert stripMnemonics("Quit __now") == "Quit _now"
    assert stripMnemonics("a__b_c") == "a_bc"

  it "keeps labels without underscores":
    assert stripMnemonics("Plain") == "Plain"
    assert stripMnemonics("trailing_") == "trailing"

describe "dbusmenu tree":

  it "finds entries and lists visible children":
    let
      a = MenuEntry(id: 1, visible: true)
      b = MenuEntry(id: 2, visible: false)
      sub = MenuEntry(id: 3, visible: true, children: @[MenuEntry(id: 4, visible: true)])
      root = MenuEntry(id: 0, visible: true, children: @[a, b, sub])
    assert root.find(4).id == 4
    assert root.find(9) == nil
    assert root.visibleChildren().len == 2
