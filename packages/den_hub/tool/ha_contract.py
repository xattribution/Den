"""Contract check: drives the Home Assistant integration's own API client against a live hub.

Starts `dart run tool/ha_hub.dart` (a hub over the demo family with an all-scopes token), loads
integrations/homeassistant/custom_components/den/api.py and models.py without Home Assistant,
and exercises every call the integration makes, including the event stream.

    python tool/ha_contract.py        (from packages/den_hub, with aiohttp installed)
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import subprocess
import sys
import types
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
COMPONENT = REPO / "integrations" / "homeassistant" / "custom_components" / "den"


def load_client():
    """Import api.py and models.py as a package without running the HA __init__."""
    package = types.ModuleType("den_client")
    package.__path__ = [str(COMPONENT)]
    sys.modules["den_client"] = package
    for name in ("models", "api"):
        spec = importlib.util.spec_from_file_location(f"den_client.{name}", COMPONENT / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[f"den_client.{name}"] = module
        spec.loader.exec_module(module)
    return sys.modules["den_client.api"]


checks: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    checks.append((name, bool(ok), detail))
    print(f"{'PASS' if ok else 'FAIL'} {name}{'' if ok else ': ' + detail}")


async def run(url: str, token: str, device: str) -> None:
    import aiohttp

    api = load_client()
    async with aiohttp.ClientSession() as session:
        client = api.DenClient(session, api.normalize_url(url), token)
        health = await client.health()
        check("health", health.ok and health.ready and health.device == device and health.api == 1, repr(health))

        directory = await client.members()
        check("members", len(directory.members) == 6 and directory.family.timezone == "America/Chicago", repr(directory.family))
        check("token info", directory.token.has("lists") and directory.token.member is None, repr(directory.token))
        leo = next(m for m in directory.members if m.name == "Leo")
        alex = next(m for m in directory.members if m.name == "Alex")

        now = datetime.now(timezone.utc)
        window = await client.events(now - timedelta(days=1), now + timedelta(days=14))
        soccer = [o for o in window.events if o.title == "Soccer practice"]
        check("events window", bool(soccer) and soccer[0].recurring and soccer[0].start.tzinfo is not None, repr(window.events[:2]))
        mine = await client.events(now, now + timedelta(days=14), member=leo.id, include_everyone=True)
        check("events for a member", all(not o.assignees or leo.id in o.assignees for o in mine.events), "")
        check("events by local date", (await client.events(date.today(), date.today() + timedelta(days=2))).start is not None)

        chores = await client.chores()
        check("chores", len(chores.chores) > 0 and bool(chores.date), repr(chores.date))
        dishes = next(c for c in chores.chores if c.title == "Dishes")
        check("chore steps", len(dishes.steps) == 3, repr(dishes.steps))
        cat = next(c for c in chores.chores if c.title == "Feed the cat")
        done = await client.complete_chore(cat.id, chores.date, done=False)
        check("complete chore (undo)", done["chore"]["done"] is False, json.dumps(done)[:200])
        done = await client.complete_chore(cat.id, chores.date, member=leo.id)
        check("complete chore", done["chore"]["done"] is True and done["chore"]["done_by"] == leo.id, json.dumps(done)[:200])
        step = await client.check_step(dishes.id, dishes.steps[0].id, chores.date, checked=True)
        check("check step", step["chore"]["steps"][0]["checked"] is True, json.dumps(step)[:200])

        lists = await client.lists()
        groceries = next(l for l in lists if l.title == "Groceries")
        check("lists", groceries.kind == "shopping" and groceries.open > 0, repr(groceries.title))
        added = await client.add_item(groceries.id, "Oat milk", qty="2", store="Costco")
        item = added["item"]
        check("add item", item["text"] == "Oat milk" and item["store"] == "Costco", json.dumps(added))
        checked = await client.update_item(item["id"], {"checked": True})
        check("check item", checked["item"]["checked"] is True, json.dumps(checked))
        renamed = await client.update_item(item["id"], {"text": "Oat milk (unsweetened)", "qty": None})
        check("rename item", renamed["item"]["text"] == "Oat milk (unsweetened)" and renamed["item"]["qty"] is None, json.dumps(renamed))
        first = groceries.items[0].id
        moved = await client.move_item(item["id"], after=None, before=first)
        check("move item", moved["item"]["id"] == item["id"], json.dumps(moved))
        after = next(l for l in await client.lists() if l.id == groceries.id)
        check("moved to the top", after.items[0].id == item["id"], repr([i.text for i in after.items[:3]]))
        check("delete item", (await client.delete_item(item["id"])) == {"ok": True})

        points = await client.points()
        check("points", points.enabled and leo.id in points.totals, repr(points.totals))
        adjusted = await client.adjust_points(leo.id, 5, "Contract check")
        check("adjust points", adjusted["balance"] == points.totals[leo.id] + 5, json.dumps(adjusted))

        today = await client.today()
        check("today", "events" in today and "gaps" in today and "chore_summary" in today, ",".join(today))
        history = await client.history(limit=5)
        check("history", history["entries"][0]["via"] == "Home Assistant", json.dumps(history["entries"][0])[:200])
        found = await client.search("Soccer")
        check("search", any(r["type"] == "event" for r in found["results"]), json.dumps(found)[:200])

        start = (now + timedelta(days=3)).replace(microsecond=0)
        created = await client.create_event({
            "title": "Contract check dentist",
            "start": api.format_when(start),
            "end": api.format_when(start + timedelta(hours=1)),
            "assignees": [alex.id],
            "reminders": [60],
        })
        event = created["event"]
        check("create event", event["title"] == "Contract check dentist" and event["start_ms"] == int(start.timestamp() * 1000), json.dumps(event)[:200])
        updated = await client.update_event(event["id"], {"location": "Bright Smiles"})
        check("update event", updated == {"ok": True})
        series = next(o for o in soccer if o.recurring)
        one = await client.update_event(series.event_id, {"location": "Field 9"}, scope="one", occurrence=series.occurrence)
        check("update one occurrence", one == {"ok": True})
        check("delete event", (await client.delete_event(event["id"])) == {"ok": True})
        try:
            await client.delete_event(event["id"])
            check("deleted event is gone", False, "no error")
        except api.DenNotFoundError:
            check("deleted event is gone", True)

        bad = api.DenClient(session, api.normalize_url(url), "den_wrong")
        try:
            await bad.members()
            check("bad token", False, "no error")
        except api.DenAuthError:
            check("bad token", True)

        messages = []

        def on_message(message):
            messages.append(message)

        connected = asyncio.Event()
        listener = api.DenStreamListener(client, on_message=on_message, on_connect=connected.set)
        task = asyncio.create_task(listener.run())
        await asyncio.wait_for(connected.wait(), 10)
        await asyncio.sleep(0.5)
        await client.add_item(groceries.id, "Stream check")
        for _ in range(50):
            if any(m.event == "changed" for m in messages):
                break
            await asyncio.sleep(0.1)
        changed = [m for m in messages if m.event == "changed"]
        check("stream changed", bool(changed) and "item" in changed[-1].data["types"] and changed[-1].data["via"] == "Home Assistant",
              repr([m.event for m in messages]))
        task.cancel()


def main() -> int:
    hub = subprocess.Popen(
        ["dart", "run", "tool/ha_hub.dart"],
        cwd=HERE.parent,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        shell=sys.platform == "win32",
    )
    try:
        line = ""
        while "{" not in line:
            line = hub.stdout.readline()
            if not line:
                print("the hub didn't start")
                return 1
        info = json.loads(line[line.index("{"):])
        asyncio.run(run(info["url"], info["token"], info["device"]))
    finally:
        hub.stdin.close()
        try:
            hub.wait(20)
        except subprocess.TimeoutExpired:
            hub.kill()
    failed = [c for c in checks if not c[1]]
    print(f"\n{len(checks) - len(failed)} of {len(checks)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
