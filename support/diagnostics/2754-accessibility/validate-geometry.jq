def key: .identity.bus + "|" + .identity.path;
def valid: . != null and .width > 0 and .height > 0 and .x != -1 and .y != -1;
def inside($host): valid and .x >= $host.x and .y >= $host.y and (.x+.width) <= ($host.x+$host.width) and (.y+.height) <= ($host.y+$host.height);
# Separate the streams at their explicit process_exit marker, including partial runs.
. as $all |
($all | map(.kind) | index("process_exit")) as $split |
($all[:$split] | map(select(.kind == "query" and .op == "GetExtents")) | group_by(key) | map({key:(.[0]|key),value:.}) | from_entries) as $before |
($all[$split+1:] | map(select(.kind == "query" and .op == "GetExtents")) | group_by(key) | map({key:(.[0]|key),value:.}) | from_entries) as $after |
($all[:$split] | map(select(.kind == "node")) | map({key:key,value:.}) | from_entries) as $before_nodes |
($all[$split+1:] | map(select(.kind == "node")) | map({key:key,value:.}) | from_entries) as $after_nodes |
($ha[0].x-$hb[0].x) as $dx | ($ha[0].y-$hb[0].y) as $dy |
{
  host_before:$hb[0],host_after:$ha[0],host_delta:{x:$dx,y:$dy},
  actual_move_observed:($dx != 0 or $dy != 0),
  process_results:[$all[]|select(.kind=="process_exit")],
  tree_summaries:[$all[]|select(.kind=="summary")],
  focused_editable_before:[$all[:$split][]|select(.kind=="node" and .editable_text and .focused)],
  focused_editable_after:[$all[$split+1:][]|select(.kind=="node" and .editable_text and .focused)],
  point_queries:[$all[]|select(.kind=="query" and (.op=="Contains" or .op=="GetAccessibleAtPoint"))],
  skipped_point_queries:[$all[]|select(.kind=="skipped")],
  screen_reader_speech_tested:false,editing_actions_tested:false,
  components:[$before|to_entries[]|.key as $id|
    (.value|map(select(.coordinate=="SCREEN"))|first) as $bs |
    (.value|map(select(.coordinate=="WINDOW"))|first) as $bw |
    ($after[$id] // []|map(select(.coordinate=="SCREEN"))|first) as $as |
    ($after[$id] // []|map(select(.coordinate=="WINDOW"))|first) as $aw |
    ($before_nodes[$id].geometry_eligible // false) as $be |
    ($after_nodes[$id].geometry_eligible // false) as $ae |
    {identity:$bs.identity,before_screen:$bs.result,after_screen:$as.result,before_window:$bw.result,after_window:$aw.result,
     before_node:$before_nodes[$id],after_node:$after_nodes[$id],before_eligible:$be,after_eligible:$ae,
     queries_present:{before_screen:($bs!=null),before_window:($bw!=null),after_screen:($as!=null),after_window:($aw!=null)},
     errors:[$bs.error,$bw.error,$as.error,$aw.error]|map(select(.!=null)),
     before_inside_host:($be and $bs.error == null and ($bs.result|inside($hb[0]))),after_inside_host:($ae and $as.error == null and ($as.result|inside($ha[0]))),
     screen_tracks_observed_move:($be and $ae and $bs.error == null and $as.error == null and ($bs.result|valid) and ($as.result|valid) and ($dx!=0 or $dy!=0) and ($as.result.x-$bs.result.x==$dx) and ($as.result.y-$bs.result.y==$dy)),
     window_stable:($be and $ae and $bw.error == null and $aw.error == null and ($bw.result|valid) and ($aw.result|valid) and ($bw.result==$aw.result))}]
}
