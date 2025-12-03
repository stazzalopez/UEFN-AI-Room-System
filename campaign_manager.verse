using { /Verse.org/Simulation }
using { /Fortnite.com/Devices }

campaign_manager := class(creative_device):
    @editable general_zone: mutator_zone_device = mutator_zone_device{}
    @editable run_timer: timer_device = timer_device{}

    # Global flags/configs
    var campaign_active: logic = false

    OnBegin<override>()<suspends>:void =
        general_zone.AgentEntersEvent.Subscribe(OnGeneralZoneAgentEntered)
        general_zone.AgentExitsEvent.Subscribe(OnGeneralZoneAgentExited)

    OnGeneralZoneAgentEntered(Agent: agent):void =
        set campaign_active = true
        run_timer.Enable(Agent)
        run_timer.Start(Agent)

    OnGeneralZoneAgentExited(Agent: agent):void =
        # Reset and disable timer for this agent when leaving general zone
        run_timer.Reset(Agent)
        run_timer.Disable(Agent)


# Per-room controller device; place one per room and wire devices via @editable
room_controller := class(creative_device):
    @editable Manager: campaign_manager = campaign_manager{}
    @editable Zone: mutator_zone_device = mutator_zone_device{}
    @editable Tracker: tracker_device = tracker_device{}
    @editable Spawners: []guard_spawner_device = array{}
    @editable ExitLock: lock_device = lock_device{}

    # Shared room progress (centralized so Individual trackers stay in sync for all players in the room)
    var RoomKills: int = 0
    var RoomTarget: int = 0

    # Grace and late-join behavior
    @editable EmptyRoomGraceSeconds: float = 2.0
    @editable bDebug: logic = false
    var LateJoinResetDone: logic = false
    var OccupancyCount: int = 0
    var InRoom: [agent]logic = map{}

    OnBegin<override>()<suspends>:void =
        Zone.AgentEntersEvent.Subscribe(OnZoneEntered)
        Zone.AgentExitsEvent.Subscribe(OnZoneExited)
        Tracker.CompleteEvent.Subscribe(OnTrackerCompleted)
        # Also monitor general zone exits to mirror room exit when needed
        Manager.general_zone.AgentExitsEvent.Subscribe(OnGeneralZoneExitRelay)
        # Subscribe to guard spawner elimination events and pre-compute target
        ComputeRoomTarget()
        for (GS : Spawners):
            GS.EliminatedEvent.Subscribe(OnGuardEliminated)

    OnZoneEntered(Agent: agent):void =
        set OccupancyCount = OccupancyCount + 1
        if (set InRoom[Agent] = true){}
        Tracker.Assign(Agent)
        # Ensure target/value are synced for late joiners
        if (RoomTarget > 0):
            Tracker.SetTarget(RoomTarget)
        Tracker.SetValue(Agent, RoomKills)
        for (S : Spawners):
            S.Enable()
        if (Manager.campaign_active = true and LateJoinResetDone = false):
            set LateJoinResetDone = true
            for (S2 : Spawners):
                S2.Reset()
            Log("[RC] Late-join reset sent (room became active while campaign running)")

    OnZoneExited(Agent: agent):void =
        # Remove and reset tracker for this agent, then handle delayed cleanup
        if (set InRoom[Agent] = false){}
        Tracker.Remove(Agent)
        Tracker.Reset(Agent)
        spawn{ HandleExitAfterDelay(Agent) }

    OnGeneralZoneExitRelay(Agent: agent):void =
        # If agent left general zone while still counted in this room, mirror exit
        if (Tmp := InRoom[Agent]):
            if (Tmp = true):
                if (set InRoom[Agent] = false){}
                Tracker.Remove(Agent)
                Tracker.Reset(Agent)
                spawn{ HandleExitAfterDelay(Agent) }

    HandleExitAfterDelay(Agent: agent)<suspends>:void =
        Sleep(EmptyRoomGraceSeconds)
        set OccupancyCount = if (OccupancyCount > 0) then (OccupancyCount - 1) else 0
        if (OccupancyCount = 0):
            for (Sd : Spawners):
                Sd.Disable()
                Sd.Reset()
            ExitLock.Close(Agent)
            set LateJoinResetDone = false
            # Reset centralized room progress so the next group starts fresh
            set RoomKills = 0
            ComputeRoomTarget()
            Log("[RC] Room emptied → spawner disabled+reset, exit lock closed, late-join rearmed")

    OnTrackerCompleted(Agent: agent):void =
        ExitLock.Open(Agent)
        Log("[RC] Tracker complete → exit lock opened")

    # Compute the total number of eliminations required for this room from configured spawners
    ComputeRoomTarget():void =
        var Total : int = 0
        for (GS : Spawners):
            set Total = Total + GS.GetSpawnLimit()
        set RoomTarget = Total

    # When any guard from our spawners is eliminated, advance shared room progress and sync all active players' trackers
    OnGuardEliminated(Result: device_ai_interaction_result):void =
        # Ignore kills when room is empty (prevents stray counts during resets)
        if (OccupancyCount = 0):
            return
        set RoomKills = RoomKills + 1
        # Sync all players currently in the room
        for (Ag -> In : InRoom):
            if (In = true):
                Tracker.SetValue(Ag, RoomKills)
                if (RoomTarget > 0 and RoomKills >= RoomTarget):
                    Tracker.Complete(Ag)
        # Safety: if no target configured, still allow completion via tracker settings
        if (RoomTarget = 0):
            for (Ag2 -> In2 : InRoom):
                if (In2 = true):
                    Tracker.Increment(Ag2)

    Log(Text: string):void =
        if (bDebug = true):
            Print(Text)

