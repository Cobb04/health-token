# Health Token Domain

## Drink Record

A durable account of one deliberate hydration action, with an estimated volume
and the absolute time when it occurred. Drink Records are the source of truth;
summaries never replace them.

## Hydration Day

One natural day in the user's current system calendar and time zone. Daily
hydration totals are reconstructed from Drink Records whenever the Hydration
Day changes. A time-zone change may therefore move a record near midnight to a
neighboring Hydration Day.

## Hydration Cycle

The interval from the most recent deliberate hydration action to the next
eligible reminder. A new Hydration Day does not restart a Hydration Cycle.

## Bottle Progress

The estimated volume recorded since the most recent completed-bottle
checkpoint. Bottle Progress can span Hydration Days and is independent of each
day's total.
