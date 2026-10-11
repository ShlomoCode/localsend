# Sender startup geometry observation failure

Run 38147283173 passes the receiver's managed-desktop readiness gate and measured geometry checks: retained geometry is X=2,Y=40,width=1000,height=700, with the known Openbox decoration offset. Receive/Send/Receiver2414 readiness is observed and its PSS stage is valid.

The sender is launched, but the later picker-ready frame still shows its ordinary Receive home page at default `(150,100)`, client size 900x600. The fixed Send/Folder clicks therefore miss the intended controls and no GTK picker is opened. `Recent` is correctly absent; this is not a picker or transfer failure.

The sender has the same startup-size restoration pattern as the receiver. Unlike the previously qualified Ubuntu harness, the new host helper omitted normalization after the rendered Sender2414 alias observation. That observation establishes initialization progress; restoring and validating geometry at that point reproduces the earlier proven harness ordering. The correction adds post-alias measured normalization for the sender, while the receiver keeps its already-passing normalization gate.

Receiver PID 4572/starttime 5342 and its sampler remain alive; complete kernel baseline/final reads have no OOM event. Its −15 exit is explicitly requested by harness SIGTERM. No folder selection, transfer control or large case occurs. The desktop RAM, disk swap, app release and product actions remain unchanged.
