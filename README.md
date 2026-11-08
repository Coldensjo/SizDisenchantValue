# Disenchant Value

See what your green, blue and purple gear is worth disenchanted, disenchant your greens with one button, and find cheap items to disenchant for profit.

Made for World of Warcraft Forever.

## Get started

1. Install **Disenchant Value** from [CurseForge](https://www.curseforge.com/wow/addons/siz-disenchantvalue).
2. Install **Auctionator** as well. Disenchant Value gets its prices from it, so without it you won't see any gold values.
3. Visit an auction house and run a scan with Auctionator.

Now hover over any green, blue or purple weapon or armor to see what it's worth.

## See what an item is worth

Item tooltips get a **Disenchant value** line. It's the average gold you'd get from the materials if you disenchanted the item and sold them.

If you see a `*` or `?`, Auctionator doesn't have prices for some of the materials yet, so the real value is likely higher. A new Auctionator scan usually fixes it.

## Disenchant with one button

You need the Enchanting profession for this.

Open your bags and a **Disenchant** button appears underneath, showing how many items are ready. Press it once per item.

- It only disenchants **green** weapons and armor. It never touches blue or purple items.
- It leaves alone anything that sells for more on the auction house than it would give disenchanted.
- To move the button, hold **Alt** and drag it.
- To use a key instead, go to Game Menu → Options → Keybindings → AddOns → Disenchant Value.
- To have the materials go straight to your bags, type `/console autoLootDefault 1` in chat once.

## Find deals at the auction house

A **Disenchant Deals** window opens beside the auction house. Press **Scan** to list every weapon and armor piece for sale, with its price, disenchant value and profit. The best deals are at the top.

> **Careful: clicking an item buys it right away, with no "are you sure?" popup.**

- A click only ever buys at the price you see. If the price is still being checked, click again.
- If the price went up, the row turns orange. Click once to accept the new price, then again to buy.
- It never buys your own auctions.
- Profit is an average. Disenchant results are random, and the auction house takes a cut when you sell.

Other things you can do in the window:

- Tick **Only show profitable** to hide items that aren't worth buying.
- Use the number buttons to show only certain item levels. Hover over one to see which materials it gives.
- Click a column name to sort by it.
- Right-click an item to open it in the normal auction house view.
- Use the **Disenchant** tab under the auction house to show or hide the window.

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
| `/dv ah` | Shows or hides the Disenchant Deals window |
