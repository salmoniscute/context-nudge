# Summarise a Claude Code transcript (JSONL).
# Run as: jq -nR --slurpfile p prices.json -f analyze.jq < transcript.jsonl
# Reads raw lines so a half-written last line is skipped instead of failing.

def ts_epoch: (. // "") | sub("\\.[0-9]+"; "") | (fromdateiso8601? // null);

# A prompt the person typed: not a tool result, not a meta/injected message,
# not the echo of a slash command.
def is_prompt:
  .type == "user" and (.isSidechain != true) and (.isMeta != true)
  and (.message.content as $c
       | if ($c | type) == "string" then
           ($c | test("^\\s*<(command-name|command-message|local-command-stdout)") | not)
         elif ($c | type) == "array" then
           ([$c[] | .type] | (index("tool_result") == null)
                             and ((index("text") != null) or (index("image") != null)))
         else false end);

def price_for($model):
  ($model // "" | (capture("(?<id>claude-[a-z]+-[0-9]+(-[0-9](?![0-9]))?)") | .id) // null) as $id
  | if $id == null then null else ($p[0].models[$id] // null) end;

def ctx_tokens:
  (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0);

def call_cost($pr):
  if $pr == null then null else
    (.input_tokens // 0) as $in
    | (.cache_read_input_tokens // 0) as $cr
    | (.cache_creation_input_tokens // 0) as $cw
    | (.cache_creation.ephemeral_1h_input_tokens // 0) as $cw1
    | (.cache_creation.ephemeral_5m_input_tokens // ([$cw - $cw1, 0] | max)) as $cw5
    | (.output_tokens // 0) as $out
    | (if $pr.long != null and ($in + $cr + $cw) > $pr.long.above then $pr.long else $pr end) as $r
    | (if .speed == "fast" then ($p[0].fast_multiplier // 2) else 1 end) as $mult
    | (($in * $r.input) + ($cw5 * $r.input * 1.25) + ($cw1 * $r.input * 2)
       + ($cr * $r.cache_read) + ($out * $r.output)) / 1000000 * $mult
  end;

def money:
  if . == null then null
  elif . < 0.01 then "<$0.01"
  else (. * 100 | round) as $c
       | "$\($c / 100 | floor).\($c % 100 | if . < 10 then "0\(.)" else tostring end)"
  end;

def sum_costs: if length == 0 then 0 else (map(. // 0) | add) end;

def tok:
  if . >= 1000000 then "\(. / 100000 | round / 10)M"
  else "\(. / 1000 | round)k" end;

reduce (inputs | fromjson? | select(type == "object")) as $e (
  {msgs: {}, last: null, round: 0, bash: {}, err: {}};
  if $e.type == "assistant" and ($e.isSidechain != true) and ($e.message.id != null)
     and ($e.message.usage != null) and ($e.message.model != "<synthetic>") then
    # One API response is written as several lines (one per content block),
    # each repeating the same usage. Key by message id so it is counted once.
    .msgs[$e.message.id] = {u: $e.message.usage, m: $e.message.model, ts: $e.timestamp, r: .round}
    | .last = $e.message.id
    | reduce ($e.message.content // [] | if type == "array" then .[] else empty end
              | select(.type == "tool_use" and .name == "Bash")) as $t
        (.; .bash[$t.id] = {cmd: ($t.input.command // ""), r: .round})
  elif $e.type == "user" then
    (if ($e.message.content | type) == "array" then
       reduce ($e.message.content[] | select(.type == "tool_result")) as $r
         (.; .err[$r.tool_use_id] = ($r.is_error == true))
     else . end)
    | if ($e | is_prompt) then .round += 1 else . end
  else . end
)
| . as $s
| [$s.msgs[]] as $all
| (if $s.last then $s.msgs[$s.last] else null end) as $L
| if $L == null then {ok: false} else
    ($all | map(. as $m | $m.u | call_cost(price_for($m.m)))) as $costs
    | ([$all[] | select(.r == $s.round)] | map(. as $m | $m.u | call_cost(price_for($m.m)))) as $round_costs
    | price_for($L.m) as $lp
    | ($L.u | ctx_tokens) as $ctx
    | ([$all[] | .u.cache_creation // {} | select(((.ephemeral_1h_input_tokens // 0) + (.ephemeral_5m_input_tokens // 0)) > 0)]
       | last // {}) as $cc
    | (if ($cc.ephemeral_1h_input_tokens // 0) > 0 then 3600 else 300 end) as $ttl
    | ([$s.bash | to_entries[]
        | select(.value.r == $s.round and $s.err[.key] != true)
        | .value.cmd
        | if test("\\bgh\\s+pr\\s+(create|merge)\\b") then "pr"
          elif test("\\bgit(\\s+-[Cc]\\s+\\S+)*\\s+push\\b") then "push"
          elif test("\\bgit(\\s+-[Cc]\\s+\\S+)*\\s+commit\\b") then "commit"
          elif test("\\b(npm|pnpm|yarn)\\s+publish\\b") then "publish"
          else empty end]
       | last // null) as $bp
    | (if $lp == null then null
       else $ctx * $lp.input * (if $ttl == 3600 then 2 else 1.25 end) / 1000000 end) as $rewrite
    | {
        ok: true,
        model: $L.m,
        priced: ($lp != null),
        ctx: $ctx,
        ttl: $ttl,
        last_ts: ($L.ts | ts_epoch),
        in_current_round: ($L.r == $s.round),
        breakpoint: (if $L.r == $s.round then $bp else null end),
        session_cost: (if ($costs | all(. == null)) then null else ($costs | sum_costs) end),
        # Some responses priced, some not (model missing from prices.json):
        # session_cost is then a lower bound.
        cost_partial: (($costs | any(. == null)) and ($costs | any(. != null))),
        round_cost: (if ($round_costs | length) == 0 or ($round_costs | all(. == null)) then null
                     else ($round_costs | sum_costs) end),
        rewrite_cost: $rewrite,
        # Tokens read on the input side, summed over every API call of the last
        # turn: each tool call re-reads the whole context.
        round_read: ([$all[] | select(.r == $s.round) | .u | ctx_tokens] | add // 0),
        round_calls: ([$all[] | select(.r == $s.round)] | length)
      }
    | .round_read_s = (.round_read | tok)
    | .session_cost_s = (.session_cost | money)
    | .round_cost_s = (.round_cost | money)
    | .rewrite_cost_s = (.rewrite_cost | money)
  end
