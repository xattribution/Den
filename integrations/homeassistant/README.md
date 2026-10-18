# Den for Home Assistant

Brings a family's [Den](https://github.com/xattribution/den) into Home Assistant: everyone's
calendars, chores and points, and the shared lists, all live from the Den hub on your network.

- A **calendar** for the family and one for each person, with create, edit and delete
  (including "this event" and "this and following" on repeating events).
- A **to-do list** for each Den list: add, check off, rename, reorder and remove items.
- **Sensors** for each person's points and chores left today, the family's chores left today,
  and when the next event starts.
- **Actions** to complete chores, check chore steps, add list items and adjust points.
- **Events** on the Home Assistant bus when a chore is completed, an item is checked, or an event
  (or one of its reminders) comes up, for automations.

Updates are pushed: the hub's event stream tells Home Assistant the moment anything changes in
Den, and Home Assistant fetches just that part. If the stream drops, it reconnects and polls every
5 minutes meanwhile.

## Requirements

- A Den hub (`den_hub`, the Docker image, or the Den app in hub mode) that Home Assistant can
  reach, by default on port 47733.
- Home Assistant 2026.2 or newer.

## Install

### With HACS

HACS installs integrations from the root of a GitHub repository, so this integration is published
from its own one, [xattribution/den-homeassistant](https://github.com/xattribution/den-homeassistant).
It isn't in HACS's default list, so add it as a custom repository:

1. In Home Assistant, open **HACS**, then the menu (⋮) at the top right, and choose
   **Custom repositories**.
2. Enter `https://github.com/xattribution/den-homeassistant`, choose the type **Integration** and
   **Add**.
3. Search HACS for **Den**, open it and choose **Download**. HACS downloads the release's
   `den.zip` and unpacks it into `config/custom_components/den`.
4. Restart Home Assistant, then [add the integration](#add-the-integration).

When a new version is released, HACS offers it as an update.

### By hand

Copy `custom_components/den` into the `custom_components` folder of your Home Assistant
configuration (so you have `config/custom_components/den/manifest.json`), or unzip a release's
`den.zip` into `config/custom_components/den`, then restart Home Assistant.

## Create a token in Den

Home Assistant signs in to the hub with an API token that a parent creates:

1. In the Den app, open **Settings → AI & automations** and add a token.
2. Call it something like "Home Assistant". It's shown in Den's History next to everything Home
   Assistant changes.
3. Choose its scopes:

   | Scope | Lets Home Assistant |
   | --- | --- |
   | `read` | See calendars, chores, lists and points. Required |
   | `calendar` | Create, edit and delete events |
   | `chores` | Complete chores and check steps |
   | `lists` | Add, check, rename, reorder and remove list items |
   | `points` | Adjust points |

   With `read` alone everything shows up, read-only.
4. Leave the token's member empty to let it act at parent level and see the whole family, or tie
   it to a person to see and do only what they can.
5. Copy the token. Den shows it once and keeps only a hash.

## Add the integration

Den hubs announce themselves on the network (`_den._tcp`), so Home Assistant usually finds yours:
open **Settings → Devices & services**, choose **Configure** on the discovered Den hub and paste
the token.

Otherwise choose **Add integration → Den** and enter the hub's address (for example
`192.168.1.20` or `http://den.local:47733`; the port defaults to 47733) and the token.

If the token is revoked or expires, Home Assistant asks for a new one. To move the hub to a new
address or swap the token, choose **Reconfigure** on the Den entry.

### Options

**Configure** on the Den entry chooses:

- **People**: who gets a calendar and sensors. People added in Den later appear on their own.
- **Lists**: which lists become to-do lists. New lists appear on their own.
- **Show family-wide events on each person's calendar**: events assigned to no one are for the
  whole family. They're always on the Family calendar; this also puts them on everyone's own.

## What you get

Entity ids below are for a family with Leo in it and lists called Groceries and Camping.

| Entity | What it shows |
| --- | --- |
| `calendar.den_family` | Every event Den shares with this token |
| `calendar.leo` | Events assigned to Leo |
| `todo.den_groceries`, `todo.den_camping` | One per list; the state is how many items are open |
| `sensor.leo_points` | Leo's points balance (only when points are on for the family) |
| `sensor.leo_chores_left_today` | Leo's chores not done yet today; attributes list what's left and what's late |
| `sensor.den_chores_left_today` | Every chore not done yet today, including "anyone" chores, with a count per person |
| `sensor.den_next_event` | When the next event starts, with its title, location and who it's for |

Each person is a device (Leo's calendar and sensors sit under "Leo"); family-wide entities and
lists sit under the "Den" hub device.

To-do items show a Den item's quantity and store in their description, as `Qty: 2 gal` and
`Store: Costco` lines. Editing those lines changes the item; a description without them is used as
the quantity.

Events imported into Den from a subscribed calendar (a school's ICS feed, say) are read-only and
can't be changed from Home Assistant.

## Actions

| Action | Fields |
| --- | --- |
| `den.complete_chore` | `chore` (title or id), `date` (default today), `member` (who did it: name or id; they earn an "anyone" chore's points, and it picks between chores with the same title), `done` (default true; false reopens) |
| `den.check_step` | `chore`, `step` (text or id), `date`, `member`, `checked` (default true). Checking the last step completes the chore |
| `den.add_item` | `list` (title or id), `text`, `qty`, `store` |
| `den.adjust_points` | `member`, `delta` (negative takes points away), `reason` |

Each takes an optional `config_entry_id` when more than one Den hub is set up, and returns a small
response (the chore's new state, the new item's id, the new balance) for scripts that ask for it.

```yaml
action: den.complete_chore
data:
  chore: Empty the dishwasher
  member: Ivy
```

## Events

| Event | When | Data |
| --- | --- | --- |
| `den_chore_completed` | A chore due today becomes done, from anywhere | `chore_id`, `title`, `date`, `done_by`, `done_by_id`, `owner`, `owner_id` (null for "anyone" chores), `points`, `owner_chores_left`, `chores_left` |
| `den_item_checked` | A list item is checked off | `item_id`, `text`, `qty`, `store`, `list`, `list_id`, `checked_by`, `checked_by_id`, `list_open` |
| `den_event_starting` | At each of an event's Den reminders, and when it starts (all-day events only at their reminders) | `title`, `start`, `end`, `all_day`, `location`, `notes`, `minutes_before` (0 at the start), `assignees` (names), `assignee_ids`, `for_everyone`, `event_id`, `uid`, `occurrence` |

Every event also carries `config_entry_id`. Names are the people's names in Den.

## Example automations

### Send Den reminders to phones

Each person's phone gets their events' reminders through the companion app; family-wide events
go to everyone. Set reminders on events in Den (for example 30 minutes before soccer).

```yaml
alias: "Den: reminders to phones"
triggers:
  - trigger: event
    event_type: den_event_starting
variables:
  phones:
    Mom: notify.mobile_app_moms_phone
    Dad: notify.mobile_app_dads_phone
    Leo: notify.mobile_app_leos_tablet
  targets: >
    {% set d = trigger.event.data %}
    {% set people = phones.keys() | list if d.for_everyone else d.assignees %}
    {% set ns = namespace(out=[]) %}
    {% for person in people if person in phones %}
      {% set ns.out = ns.out + [phones[person]] %}
    {% endfor %}
    {{ ns.out }}
actions:
  - repeat:
      for_each: "{{ targets }}"
      sequence:
        - action: "{{ repeat.item }}"
          data:
            title: "{{ trigger.event.data.title }}"
            message: >
              {% set d = trigger.event.data %}
              {{ d.title }} {{ 'is starting' if d.minutes_before == 0
                 else 'in ' ~ d.minutes_before ~ ' minutes' }}
              {%- if d.location %} at {{ d.location }}{% endif %}.
```

### Celebrate when a kid's chores are all done

```yaml
alias: "Den: Leo finished his chores"
triggers:
  - trigger: event
    event_type: den_chore_completed
    event_data:
      owner: Leo
      owner_chores_left: 0
actions:
  - action: light.turn_on
    target:
      entity_id: light.living_room
    data:
      flash: long
  - action: tts.speak
    target:
      entity_id: tts.piper
    data:
      media_player_entity_id: media_player.kitchen_speaker
      message: "Nice work, Leo! All your chores are done for today."
```

### Put milk on the grocery list when the fridge says so

```yaml
alias: "Den: milk is running low"
triggers:
  - trigger: state
    entity_id: binary_sensor.fridge_milk_low
    to: "on"
actions:
  - action: todo.get_items
    target:
      entity_id: todo.den_groceries
    data:
      status: needs_action
    response_variable: groceries
  - condition: template
    value_template: >
      {{ 'milk' not in groceries['todo.den_groceries']['items']
         | map(attribute='summary') | map('lower') | list }}
  - action: den.add_item
    data:
      list: Groceries
      text: Milk
      qty: 1 gal
```

## Assist and Den's MCP tools

The hub also serves Den's tools (today's plan, the week, adding events, chores and list items,
points) over MCP at `http://<hub>:47733/mcp`. Home Assistant's own **Model Context Protocol**
integration can connect to it: add that integration with the hub's `/mcp` address and approve the
request in the Den app under **Settings → AI & automations** when asked. Then, in the options of
your conversation agent (an AI one, such as OpenAI, Anthropic, Google or Ollama), turn on the Den
tools, and Assist can answer "what's on tomorrow?" or "add diapers to the Costco list" with
Den itself.

## Troubleshooting

- **Diagnostics** on the Den entry show whether the event stream is connected, the token's scopes
  and counts of what was fetched. The token, names and titles are left out.
- Times follow the family's time zone in Den. "Today" for chores rolls over at the family's
  midnight.
- Debug logging: add `custom_components.den: debug` under `logger:`.

## Publishing to HACS

For maintainers. The integration is developed in the Den repository, under
[`integrations/homeassistant`](https://github.com/xattribution/den/tree/main/integrations/homeassistant),
and published from `xattribution/den-homeassistant`, which has at its root what HACS looks for.
`scripts/prepare_hacs_repo.py` (in `integrations/homeassistant`) writes that repository's files
into a folder:

| File | What it is |
| --- | --- |
| `hacs.json` | The integration's `hacs.json`, set to install from releases: `"zip_release": true` and `"filename": "den.zip"` |
| `custom_components/den/` | The integration, without `__pycache__` folders or `.pyc` files |
| `README.md` | This README, which HACS shows on the integration's page |
| `LICENSE` | Den's license (AGPL-3.0) |

With `--zip PATH` it also writes `den.zip`: the contents of `custom_components/den`, with
`manifest.json` at the top of the zip, which is how HACS expects it (it unpacks the zip into
`config/custom_components/den`). From `integrations/homeassistant`:

```bash
python scripts/prepare_hacs_repo.py ../../dist/den-homeassistant --zip ../../dist/den.zip
```

The script needs only Python 3.10 or newer. It won't write into a folder that has anything in it unless you
pass `--force`, which replaces `hacs.json`, `README.md`, `LICENSE` and `custom_components/den` and
leaves everything else, like `.git`, alone. `--version 0.2.0` (or `v0.2.0`) refuses to go on unless
that's the version in `manifest.json`; add `--set-version` to put it in the copied `manifest.json`
instead. HACS also asks integrations for brand images (at least
`custom_components/den/brand/icon.png`); the script points it out while they're missing.

CI's `homeassistant-release` job runs after the integration's tests on every push and pull
request. It builds both and uploads them as the workflow artifacts `den-homeassistant-zip` and
`den-homeassistant-repo`. On a `v*` tag, `homeassistant-publish` (the only job allowed to write
to the repository) attaches that `den.zip` to Den's GitHub release for the tag. The zip carries the version in `manifest.json`, which needn't match Den's tag. CI never
pushes to den-homeassistant; publishing there is done by hand:

1. Once: create the public GitHub repository `xattribution/den-homeassistant` and clone it.
2. Set the new `version` in `custom_components/den/manifest.json` in Den.
3. From `integrations/homeassistant`, write the new version into the clone (here it sits next to
   the Den repository) and `den.zip` beside it:

   ```bash
   python scripts/prepare_hacs_repo.py ../../../den-homeassistant --force --version 0.2.0 --zip ../../../den.zip
   ```

4. In the clone, commit and push.
5. Publish a GitHub release there tagged `v0.2.0` with `den.zip` attached (this one, or one CI
   built from the same commit), for example from the clone:

   ```bash
   gh release create v0.2.0 ../den.zip --repo xattribution/den-homeassistant --title v0.2.0 --generate-notes
   ```

   HACS takes the version from the latest release's tag and installs the `den.zip` attached to
   it; a tag without a release isn't enough.
