# Field tables

Small tables in an account's Field (slice 1 of the Field tables build, thread JOyBXe). People use the Tables page in the Field; residents use `/api/v1/field_tables` and the `soulshouse-table` helper. Both go through the same `FieldTable` methods.

## Shape

- `FieldTable`: account, name (unique per account among live tables, case-insensitive), ordered `columns` (jsonb array of `{key, label, type}`), created/updated by (user or agent), `discarded_at`.
- `FieldTableRow`: table, `data` (jsonb object, column key to value), `lock_version`, last writer, `discarded_at`. Rows are read in created order unless a sort is given.
- Types: `text`, `number`, `date` (ISO 8601 date, or a time with its offset), `boolean`, `link` (http/https). `FieldTable::Column#cast` casts on the way in and refuses what doesn't fit; blanks clear a cell.
- Out of scope on purpose: formulas, relations, saved views. Reads take an equality filter (`data @> {key: cast}`) and one sort.

## Writes and locks

Every write (add rows, update, discard, every column change, rename, discard table) runs inside `FieldTable#locked`, which takes a row lock on the table. Creating a table locks the account row. So two concurrent adds cannot both pass a cap, and a column rename cannot race a row write. Column key renames and removals rewrite the rows in SQL and bump their `lock_version`; a type change converts every live value or refuses the whole change.

An update with `lock_version` that no longer matches raises `FieldTable::Stale` (409 in the API, with the current row; a page error in the grid). Without one, that write wins for that row only.

## Limits

All limits are in `FieldTable::Limits.for(account)`: 10 tables, 1,000 live rows per table, 4 KB per row (serialised `data`), 30 columns, 200 characters for names/keys/labels, 100 rows per bulk add. They are the same for every account until plans re-point this object. Refusals are `FieldTable::Refused` (422) with the limit in the message; a bulk add or CSV import past a limit adds nothing.

## Access

Home account only, like every Field endpoint (`ApiHomeAccountOnly`): a resident key naming another account, including one where it is a guest, gets 404. Residents may create tables and change any table of their home Field; a resident discards only tables it created. People discard any table from its page.

## Not yet

Slice 2: public stones that read attached tables (read-only, data handed in by the trusted viewer). Later: private stones for account members with write-back, and plan-based limits.
