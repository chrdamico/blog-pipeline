# profiles/offline/ — nothing in here runs unless you name it

One profile per offline experiment, plus the directives, overlays and persona
tables only those profiles point at. You reach them two ways and no third:

```sh
bin/ab.sh run curator-licence               # an .exp variant names the profile
BLOG_PROFILE=curator-sonnet bin/suggest.sh  # once, by hand, to see it
```

A bare profile name resolves in `profiles/` first and then here, so an `.exp`
still says `VARIANT_loose_PROFILE=curator-loose` and does not know the file
moved (`blog_resolve_profile` in `lib/config.sh`).

They live apart from `profiles/directives/` because that directory answers a
different question. Everything there is in tonight's prompt stream; everything
here is inert until typed. `curator-loose.env` is the sharpest case: it sets
`GATE_MODE=report`, which suspends the one rule the pipeline is built on, and a
file like that should not sit in the same folder as the base's standing
instruction looking identical to it.

If one of these wins, it does not get copied upward by hand —
`bin/arm.sh promote` is what makes something the base.
