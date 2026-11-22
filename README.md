# Disenchant Value

See what your green, blue and purple gear is worth disenchanted, disenchant your greens with one button, and find cheap items to disenchant for profit.

Made for World of Warcraft Forever.

## Get started

1. Install **Disenchant Value** from [CurseForge](https://www.curseforge.com/wow/addons/siz-disenchantvalue).
2. Install **Auctionator** as well. Disenchant Value gets its prices from it, so without it you won't see any gold values.
3. Visit an auction house and run a scan with Auctionator.

Now hover over any green, blue or purple weapon or armor to see what it's worth.

## See what an item is worth

Item tooltips get a **Disenchant value** line. It's the average gold you'd get from the materials if you disenchanted the item and sold them, after the auction house's 5% cut. Hold **Shift** to also see the value before the cut.

If you see a `*` or `?`, Auctionator doesn't have prices for some of the materials yet, so the real value is likely higher. A new Auctionator scan usually fixes it.

If you see **(old price)**, Auctionator has no current price for one of the materials, so a price saved earlier (possibly on another character's realm or faction) is used. A new Auctionator scan fixes it.

### How the value is worked out

Each possible result's chance × its average count × its latest Auctionator price, added up. The 5% cut is taken from that unrounded total, and the result is rounded down to the copper once: value = floor(total × 0.95). The Shift "Before 5% AH cut" line is floor(total). For example, Green Iron Bracers at a total of 1566.9c show 14s 88c (1488c) after the cut.

### WoW Forever table notes

- Green **weapons** of item level 21-30 give Greater Magic Essence on Forever instead of Lesser/Greater Astral Essence (dust and shard odds unchanged).
- Green items of item level 51+ give a 22% essence (armor) or 22% dust (weapons) and a 3% shard, instead of the 20%/5% this addon used before (Classic reference: armor 20/5, weapons 22/3). The live Forever evidence for this is a single table, BootyBayBroker's (observed odds, the same for armor and weapons); Classic references such as warcraft.wiki.gg list 20%/5% for armor and 22%/3% for weapons.
- Blue items of item level 56+ still count a 0.5% Nexus Crystal (worth about 6.6% of their value at current prices); sources disagree on it.
- Values sent to other addons (DisenchantValueAPI, e.g. Auctionator's "DE Value" column) are after the 5% cut too, unless `/dv ahcut off`.

## Disenchant with one button

You need the Enchanting profession for this.

Open your bags and a **Disenchant** button appears underneath, showing how many items are ready. Press it once per item. It works with the normal bags and with bag addons such as Baganator, Bagnon, AdiBags, ArkInventory and ElvUI.

- It only disenchants **green** weapons and armor. It never touches blue or purple items.
- It leaves alone anything that sells for more on the auction house than it would give disenchanted. Both sides are compared after the 5% cut, each rounded down the same way (with `/dv ahcut off`, both without it).
- To move the button, hold **Alt** and drag it.
- The button hides during combat and comes back when combat ends.
- To use a key instead, go to Game Menu → Options → Keybindings → AddOns → Disenchant Value.
- To have the materials go straight to your bags, type `/console autoLootDefault 1` in chat once.

## Find deals at the auction house

A **Disenchant Deals** window opens beside the auction house. Press **Scan** to list every weapon and armor piece for sale, with its price, disenchant value and profit. The best deals are at the top.

> **Careful: clicking an item buys it right away, with no "are you sure?" popup.**

- A click only ever buys at the price you see. If the price is still being checked, click again.
- If the price went up, the row turns orange. Click once to accept the new price, then again to buy.
- It never buys your own auctions.
- Profit is an average: the disenchant value (after the 5% auction house cut on the materials) minus the price. Disenchant results are random.
- A gray disenchant value uses an old saved price (see above).

Other things you can do in the window:

- Tick **Only show profitable** to hide items that aren't worth buying.
- Use the number buttons to show only certain item levels. Hover over one to see which materials it gives.
- Click a column name to sort by it.
- Right-click an item to open it in the normal auction house view.
- Use the **Disenchant** tab under the auction house to show or hide the window.
- Drag the window by its title (or any empty spot) to move it, for example when it doesn't fit beside the auction house. It remembers where you put it. `/dv ahreset` puts it back.

## Chat commands

You don't need these for normal use.

| Type this | What it does |
|---|---|
| `/dv list` | Shows what the button will disenchant, what it will skip, and why |
| `/dv ignore` + item | Tells the button to never disenchant that item. Shift-click the item to add it after the command |
| `/dv unignore` + item | Lets the button disenchant that item again |
| `/dv ahcheck off` | Makes the button also disenchant items that would sell for more. `/dv ahcheck on` turns the check back on |
| `/dv button` | Shows or hides the button |
| `/dv attach` | Puts the button back under your bags |
| `/dv status` | Shows why the button is or isn't showing (useful when reporting a problem) |
| `/dv ah` | Shows or hides the Disenchant Deals window |
| `/dv ahreset` | Puts the Disenchant Deals window back beside the auction house, at normal size |
| `/dv ahscale 0.8` | Makes the Disenchant Deals window smaller or bigger (0.5 to 1.5) |
| `/dv ahcut off` | Shows values without taking off the auction house's 5% cut. `/dv ahcut on` takes it off again (the default) |
