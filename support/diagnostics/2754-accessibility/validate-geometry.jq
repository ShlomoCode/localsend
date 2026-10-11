def idkey: .bus + "|" + .path;
def key: .identity | idkey;
def valid: . != null and .width > 0 and .height > 0 and .x != -1 and .y != -1;
def inside($host): valid and $host != null and .x >= $host.x and .y >= $host.y and (.x+.width) <= ($host.x+$host.width) and (.y+.height) <= ($host.y+$host.height);
def phase($name):
  . as $records |
  [.[]|select(.kind=="query")] as $queries |
  [.[]|select(.kind=="query_enter")] as $entries |
  [.[]|select(.kind=="summary")] as $summaries |
  [.[]|select(.kind=="process_exit")] as $exits |
  [.[]|select(.kind=="node" and .editable_text and .focused and .editable_state and .geometry_eligible and .component)] as $targets |
  [$entries[]|.call_id as $call|select([$queries[]|select(.call_id==$call)]|length!=1)] as $unmatched |
  {phase:$name,records:$records,queries:$queries,targets:$targets,summaries:$summaries,process_results:$exits,
   errors:[$queries[]|select(.error!=null)],unmatched_entries:$unmatched,
   tree_anomalies:[$records[]|select(.kind=="cycle" or .kind=="revisit" or .kind=="tree_gap")],
   point_queries:[$queries[]|select(.op=="Contains" or .op=="GetAccessibleAtPoint" or .op=="AncestorContains" or .op=="AncestorGetAccessibleAtPoint")],
   skipped_point_queries:[$records[]|select(.kind=="skipped" or .kind=="ancestor_skipped")]} |
  .complete = (($exits|length==1 and .[0].status==0) and
    ($summaries|length==1 and .[0].application_found and (.[0].truncated|not) and .[0].focused_editable_nodes==1) and
    ($targets|length==1) and ($unmatched|length==0) and (.errors|length==0) and (.tree_anomalies|length==0));
def extent($p;$id;$coord): [$p.queries[]|select(.op=="GetExtents" and (key)==$id and .coordinate==$coord)]|if length==1 then .[0] else null end;
def metadata_complete($p;$id):
  ["GetName","GetRole","GetStateSet","StateContainsFocused","StateContainsEditable","StateContainsDefunct","StateContainsVisible","StateContainsShowing","ComponentInterface","EditableTextInterface","GetInterfaces","GetChildCount"] |
  all(.[];. as $op|[$p.queries[]|select((key)==$id and .op==$op)]|length==1);
def points_complete($p;$target):
  ($target.identity|idkey) as $id |
  ["SCREEN","WINDOW"]|all(.[];. as $coord|
    ([$p.queries[]|select((key)==$id and .coordinate==$coord and .op=="Contains")]|length==2) and
    ([$p.queries[]|select((key)==$id and .coordinate==$coord and .op=="GetAccessibleAtPoint")]|length==1));
def ancestry_proven($p;$target):
  (($target.ancestry // [])+[$target.identity]) as $chain |
  ($target!=null and ($chain|length)>1 and all(range(0;($chain|length)-1); . as $i |
    [$p.records[]|select(.kind=="edge" and .identity==$chain[$i] and .child_identity==$chain[$i+1])]|length==1));
def ancestor_checks($p;$target):
  ($target.identity|idkey) as $target_id |
  ($target.ancestry // []) as $chain |
  [$chain[]|. as $identity|($identity|idkey) as $ancestor_id|
    ([$p.records[]|select(.kind=="node" and (key)==$ancestor_id)]|first) as $node |
    select($node.component and $node.geometry_eligible) |
    ["SCREEN","WINDOW"][] as $coord |
    [$p.queries[]|select((key)==$ancestor_id and (.target_identity|idkey)==$target_id and .coordinate==$coord and .op=="AncestorContains")] as $contains |
    [$p.queries[]|select((key)==$ancestor_id and (.target_identity|idkey)==$target_id and .coordinate==$coord and .op=="AncestorGetAccessibleAtPoint")] as $hits |
    ($chain|map(idkey)|index($ancestor_id)) as $index |
    {identity:$identity,coordinate:$coord,contains:$contains,point_hits:$hits,
     complete:(($contains|length)==1 and ($hits|length)==1),
     contains_target_center:($contains|length==1 and .[0].error==null and .[0].result==true),
     hit_on_target_path:($hits|length==1 and .[0].error==null and .[0].result!=null and
       ((.[0].result|idkey) as $hit|(($chain[$index+1:]+[$target.identity])|map(idkey)|index($hit))!=null))}];
. as $all |
($all|map(.kind)|index("process_exit")) as $split |
($all[:(($split // ($all|length))+1)]|phase("before")) as $before |
($all[(($split // ($all|length))+1):]|phase("after")) as $after |
($before.targets[0] // null) as $bt | ($after.targets[0] // null) as $at |
($xb[0].client // null) as $bc | ($xa[0].client // null) as $ac |
(($ac.x // 0)-($bc.x // 0)) as $dx | (($ac.y // 0)-($bc.y // 0)) as $dy |
($bt.identity|idkey) as $target_id |
extent($before;$target_id;"SCREEN") as $bts | extent($after;$target_id;"SCREEN") as $ats |
extent($before;$target_id;"WINDOW") as $btw | extent($after;$target_id;"WINDOW") as $atw |
([$bt.ancestry[]?,$bt.identity]|map(select(.!=null)|idkey)) as $target_path |
[$before.records[]|select(.kind=="node" and .component)|. as $bn|(key) as $id|
  ([$after.records[]|select(.kind=="node" and (key)==$id)]|first) as $an |
  extent($before;$id;"SCREEN") as $bs | extent($before;$id;"WINDOW") as $bw |
  extent($after;$id;"SCREEN") as $as | extent($after;$id;"WINDOW") as $aw |
  {identity:$bn.identity,before_node:$bn,after_node:$an,on_target_path:($target_path|index($id)!=null),
   before_screen:$bs.result,before_window:$bw.result,after_screen:$as.result,after_window:$aw.result,
   complete:($bs!=null and $bw!=null and $as!=null and $aw!=null),
   eligible:($bn.geometry_eligible and ($an.geometry_eligible // false)),
   errors:([$bs.error,$bw.error,$as.error,$aw.error]|map(select(.!=null))),
   before_inside_client:($bs.result|inside($bc)),after_inside_client:($as.result|inside($ac)),
   nested_field_bounds:(($bts.result|inside($bs.result)) and ($ats.result|inside($as.result)) and ($btw.result|inside($bw.result)) and ($atw.result|inside($aw.result))),
   before_origin_calibrated:(($bs.result|valid) and ($bw.result|valid) and $bc!=null and $bs.result.x-$bw.result.x==$bc.x and $bs.result.y-$bw.result.y==$bc.y and $bs.result.width==$bw.result.width and $bs.result.height==$bw.result.height),
   after_origin_calibrated:(($as.result|valid) and ($aw.result|valid) and $ac!=null and $as.result.x-$aw.result.x==$ac.x and $as.result.y-$aw.result.y==$ac.y and $as.result.width==$aw.result.width and $as.result.height==$aw.result.height),
   screen_tracks_observed_move:(($bs.result|valid) and ($as.result|valid) and $as.result.x-$bs.result.x==$dx and $as.result.y-$bs.result.y==$dy and $as.result.width==$bs.result.width and $as.result.height==$bs.result.height),
   window_stable:(($bw.result|valid) and ($aw.result|valid) and $bw.result==$aw.result)}] as $components |
ancestor_checks($before;$bt) as $bp | ancestor_checks($after;$at) as $ap |
($components|map(select(.on_target_path and .before_node.geometry_eligible))) as $relevant |
{host_before:$hb[0],host_after:$ha[0],x11_before:$xb[0],x11_after:$xa[0],x11_before_end:$xbe[0],x11_after_end:$xae[0],x11_process_results:[$xbs[0],$xas[0],$xbes[0],$xaes[0]],move_process_result:$move[0],
 host_delta:{x:$ha[0].x-$hb[0].x,y:$ha[0].y-$hb[0].y},client_delta:{x:$dx,y:$dy},
 phases:([$before,$after]|map(del(.queries,.records))),components:$components,ancestor_checks:{before:$bp,after:$ap},
 gates:{processes_and_trees_complete:($before.complete and $after.complete),
   independent_origin_observed:($xbs[0].status==0 and $xas[0].status==0 and ($bc|valid) and ($ac|valid) and $xb[0].client_pid==$pid and $xa[0].client_pid==$pid and $bc.map_state==2 and $ac.map_state==2),
   origin_stable_during_queries:($xbes[0].status==0 and $xaes[0].status==0 and $xb[0].client==$xbe[0].client and $xa[0].client==$xae[0].client and $xbe[0].client_pid==$pid and $xae[0].client_pid==$pid),
   actual_move_observed:($dx!=0 or $dy!=0),
   pure_move:($bc.window_id==$ac.window_id and $xb[0].root_id==$xa[0].root_id and $bc.width==$ac.width and $bc.height==$ac.height and $hb[0].width==$ha[0].width and $hb[0].height==$ha[0].height and $move[0].status==0),
   same_focused_editable_target:($bt!=null and $at!=null and $bt.identity==$at.identity and $bt.ancestry==$at.ancestry),
   traversal_ancestry_proven:(ancestry_proven($before;$bt) and ancestry_proven($after;$at)),
   live_target_queries_complete:($bt!=null and $at!=null and metadata_complete($before;$target_id) and metadata_complete($after;$target_id) and points_complete($before;$bt) and points_complete($after;$at)),
   relevant_geometry_complete:($relevant|length>0 and all(.[];.complete and (.errors|length==0))),
   relevant_geometry_correct:($relevant|length>0 and all(.[];.eligible and .before_inside_client and .after_inside_client and .nested_field_bounds and .before_origin_calibrated and .after_origin_calibrated and .screen_tracks_observed_move and .window_stable)),
   target_contains_correct:([$before.point_queries[],$after.point_queries[]]|map(select(.op=="Contains" and (key)==$target_id))|length==8 and all(.[];.error==null and .result==(.probe=="inside"))),
   ancestor_queries_complete:(($bp|length)>0 and ($ap|length)>0 and all($bp[],$ap[];.complete)),
   ancestor_routing_correct:(($bp|length)>0 and ($ap|length)>0 and all($bp[],$ap[];.contains_target_center and .hit_on_target_path))},
 screen_reader_speech_tested:false,editing_actions_tested:false} |
.probe_status = (if (.gates.processes_and_trees_complete and .gates.independent_origin_observed and .gates.origin_stable_during_queries and .gates.actual_move_observed and .gates.pure_move and .gates.same_focused_editable_target and .gates.traversal_ancestry_proven and .gates.live_target_queries_complete and .gates.relevant_geometry_complete and .gates.ancestor_queries_complete)|not then "incomplete"
  elif all(.gates[];.) then "pass" else "fail" end) |
.failed_gates = [.gates|to_entries[]|select(.value!=true)|.key]
