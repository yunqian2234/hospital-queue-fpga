`timescale 1ns/1ps
// Hospital business core (registered in the TD project since stage C).
// All inputs/outputs share clk. key_press is the debounced one-cycle bitmask.
// TICKET_MODE=1 (V7, used by the top): K8 issues the next ticket 001..020 and
// K1 may only call a number that has been issued; waiting_count = issued - called.
// Taking a ticket is a pure state change, not an event (no voice). TICKET_MODE=0
// keeps the original behaviour (K8 reserved, K1 calls up to 020).
// 10/25 multi-room (one department, up to 4 consulting rooms, ONE shared queue): the staff
// keys K1 call next / K2 replay / K3 confirm help arrive with key_room (0..3 = room 1..4).
// K1 gives the queue head (call_number + 1) to that room; K2 replays that room's own current
// number; K3 records which room took the help request (help_room). room_numbers holds every
// room's current patient, last_room the room of the latest call. CALL / REPLAY / HELP_ACK
// events carry the room in the card field, so the voice can say "到 X 诊室就诊".
// Expression cards 1..5 were removed (10/25); a touch card request other than card 0 (help)
// is invalid.
// QDEPTH (default eight) total outstanding events, including at most one dispatched event.
// event_valid && event_ready transfers ownership; event_done retires by sequence.
module hospital_app_core #(
    parameter TICKET_MODE = 0, SEMANTIC_INPUT = 0,
    parameter integer ROOMS = 4,        // rooms served; room_numbers of the others stay 0
    parameter integer QDEPTH = 8        // outstanding events incl. the dispatched one (10/25: 4..8)
)(
    input wire clk, rst,
    input wire [7:0] key_press,
    input wire [1:0] key_room,          // room of the K1/K2/K3 pulse (link commands)
    input wire event_ready, event_done,
    input wire [15:0] event_done_seq,
    output reg [4:0] call_number,
    output reg [4:0] issued_number,     // last ticket handed out (0 = none yet)
    output wire [4:0] waiting_count,    // issued but not yet called
    output reg [2:0] selected_card, last_card,
    output reg last_card_valid,
    output reg [1:0] help_state,
    output reg [15:0] help_seq,
    output wire event_valid,
    output wire [43:0] event_data,
    output reg [3:0] queued_events,
    output reg busy,
    output reg [15:0] active_seq,
    output reg [7:0] accepted_keys,
    output wire [7:0] rejected_keys,
    output reg [7:0] reject_invalid, reject_duplicate, reject_full, reject_conflict,
    output reg overflow_sticky, completion_error_sticky,
    // Confirmed semantic request. Accepted on valid && ready; result one cycle later.
    // kind 2=replay(snapshot number), 3=expression(snapshot card), 6=ticket(no voice).
    input wire request_valid, input wire [2:0] request_kind,
    input wire request_source, input wire [4:0] request_number,
    input wire [2:0] request_card,
    output wire request_ready, output reg request_done, request_accepted,
    output reg [2:0] request_result, // 0 accepted,1 invalid,2 duplicate,3 full,4 conflict
    output reg [4:0] history1, history2, history3,
    output reg [43:0] active_event,
    output reg [19:0] room_numbers,     // {room4, room3, room2, room1} current patient, 0 = none
    output reg [1:0] last_room,         // room of the latest call
    output reg [1:0] help_room          // room that confirmed the latest help request
);
    localparam [2:0] CALL=1, REPLAY=2, EXPRESSION=3, HELP=4, HELP_ACK=5;
    localparam [1:0] HELP_IDLE=0, HELP_PENDING=1, HELP_CONFIRMED=2;
    // Entry = origin key[2:0], seq[15:0], kind[2:0], patient[0],
    //         number[4:0], card[2:0], associated help request seq[15:0].
    reg [46:0] queue [0:QDEPTH-1];
    reg [46:0] queue_n [0:QDEPTH-1];
    reg [15:0] next_seq, next_seq_n, active_seq_n, help_seq_n;
    reg [2:0] active_key, active_key_n, selected_n, last_card_n;
    reg [4:0] number_n, issued_n;
    reg [1:0] help_state_n;
    reg [3:0] queued_n;
    reg busy_n, last_valid_n, overflow_n, completion_error_n;
    // K2, K6, K7 allow only one unfinished event per key.
    reg [7:0] pending_once, pending_once_n;
    // One bit per legal replay number. It covers the active event and queue.
    // Updates follow the original retire/dispatch/key/request ordering; there
    // is no wide scan through partially updated queue muxes in the input path.
    reg [20:1] pending_replay, pending_replay_n;
    reg [7:0] accept_n, invalid_n, duplicate_n, full_n, conflict_n;
    integer i, k, q;
    reg request_done_n,request_accept_n;
    reg [2:0] request_result_n;
    reg [2:0] request_origin;
    reg [43:0] active_event_n;
    reg [19:0] room_numbers_n;
    reg [1:0] last_room_n, help_room_n;
    wire [4:0] room_cur = room_numbers[{key_room, 2'b00} + key_room +: 5];   // key_room's patient
    assign request_ready = SEMANTIC_INPUT != 0 && !rst;
    function replay_exists;
        input [4:0] n;
        begin
            replay_exists=(n>=1 && n<=20) ? pending_replay_n[n]:1'b0;
        end
    endfunction

    assign event_valid = !rst && !busy && queued_events!=0;
    assign event_data = event_valid ? queue[0][43:0] : 44'd0;
    assign rejected_keys = reject_invalid | reject_duplicate | reject_full | reject_conflict;
    assign waiting_count = TICKET_MODE!=0 ? issued_number - call_number : 5'd0; // called <= issued

    // One combinational enqueue, called in ascending key order for simultaneous
    // inputs. Every rejected input is reported; rejected actions do not change state.
    task enqueue;
        input [2:0] origin, kind;
        input patient;
        input [4:0] number;
        input [2:0] card;
        input [15:0] request_seq;
        begin
            if (queued_n + {3'd0,busy_n} < QDEPTH) begin
                queue_n[queued_n] = {origin,next_seq_n,kind,patient,number,card,request_seq};
                queued_n = queued_n + 1'b1;
                next_seq_n = next_seq_n + 1'b1;
                accept_n[origin] = 1'b1;
                if (SEMANTIC_INPUT!=0 && kind==REPLAY) pending_replay_n[number]=1'b1;
                if (origin==1 || origin==5 || origin==6) pending_once_n[origin]=1'b1;
            end else begin
                full_n[origin] = 1'b1;
                overflow_n = 1'b1;
            end
        end
    endtask

    always @* begin
        active_event_n=active_event; pending_replay_n=pending_replay;
        number_n=call_number; issued_n=issued_number; selected_n=selected_card;
        last_card_n=last_card; last_valid_n=last_card_valid;
        help_state_n=help_state; help_seq_n=help_seq;
        next_seq_n=next_seq; active_seq_n=active_seq; active_key_n=active_key;
        queued_n=queued_events; busy_n=busy; pending_once_n=pending_once;
        overflow_n=overflow_sticky; completion_error_n=completion_error_sticky;
        accept_n=0; invalid_n=0; duplicate_n=0; full_n=0; conflict_n=0;
        request_done_n=0;request_accept_n=0;request_result_n=0;request_origin=0;
        room_numbers_n=room_numbers; last_room_n=last_room; help_room_n=help_room;
        for(i=0;i<QDEPTH;i=i+1) queue_n[i]=queue[i];

        if (event_done) begin
            if (busy && event_done_seq==active_seq) begin
                busy_n=0; active_seq_n=0; active_key_n=0; active_event_n=0;
                pending_once_n[active_key]=0;
                if (SEMANTIC_INPUT!=0 && active_event[27:25]==REPLAY)
                    pending_replay_n[active_event[23:19]]=1'b0;
            end else completion_error_n=1;
        end
        // Do not retire and start another event in the same cycle: an explicit
        // idle cycle separates ownership changes, simplifying the future player.
        if (event_valid && event_ready) begin
            active_event_n=event_data;
            busy_n=1; active_seq_n=queue[0][43:28]; active_key_n=queue[0][46:44];
            queued_n=queued_n-1'b1;
            for(i=0;i<QDEPTH-1;i=i+1) queue_n[i]=queue[i+1];
            queue_n[QDEPTH-1]=0;
        end

        if (key_press[3] && key_press[4]) conflict_n[4:3]=2'b11;
        else if (key_press[3]) begin
            selected_n=selected_card==0 ? 3'd5 : selected_card-1'b1;
            accept_n[3]=1;
        end else if (key_press[4]) begin
            selected_n=selected_card==5 ? 3'd0 : selected_card+1'b1;
            accept_n[4]=1;
        end
        if (key_press[7]) begin
            if (TICKET_MODE==0 || issued_number==5'd20) invalid_n[7]=1; // reserved / tickets used up
            else begin issued_n=issued_number+1'b1; accept_n[7]=1; end
        end

        // Semantic checks and snapshots use PRE-CYCLE business state. Therefore
        // NEXT+REPLAY replays the old number; SELECT+CONFIRM confirms the old card.
        for(k=0;k<7;k=k+1) begin
            if(key_press[k]) begin
                case(k)
                    0: begin
                        if(call_number==20 || (TICKET_MODE!=0 && call_number>=issued_number)) invalid_n[0]=1;
                        else begin
                            enqueue(0,CALL,0,call_number+5'd1,{1'b0,key_room},0);
                            if(accept_n[0]) begin
                                number_n=call_number+1'b1;
                                room_numbers_n[{key_room, 2'b00} + key_room +: 5]=call_number+5'd1;
                                last_room_n=key_room;
                            end
                        end
                    end
                    1: begin                                    // the room's own patient
                        if(room_cur==0) invalid_n[1]=1;
                        else if((SEMANTIC_INPUT!=0 && replay_exists(room_cur)) ||
                                (SEMANTIC_INPUT==0 && pending_once_n[1])) duplicate_n[1]=1;
                        else enqueue(1,REPLAY,0,room_cur,{1'b0,key_room},0);
                    end
                    6: begin
                        if(call_number==0) invalid_n[6]=1;
                        else if((SEMANTIC_INPUT!=0 && replay_exists(call_number)) ||
                                (SEMANTIC_INPUT==0 && pending_once_n[6])) duplicate_n[6]=1;
                        else enqueue(6,REPLAY,1,call_number,{1'b0,last_room},0);
                    end
                    2: begin
                        if(help_state!=HELP_PENDING) invalid_n[2]=1;
                        else begin
                            enqueue(2,HELP_ACK,0,call_number,{1'b0,key_room},help_seq);
                            if(accept_n[2]) begin help_state_n=HELP_CONFIRMED; help_room_n=key_room; end
                        end
                    end
                    5: begin
                        if(pending_once_n[5] || (selected_card==0 && help_state==HELP_PENDING))
                            duplicate_n[5]=1;
                        else begin
                            if(selected_card==0) begin
                                enqueue(5,HELP,1,call_number,selected_card,next_seq_n);
                                if(accept_n[5]) begin
                                    help_state_n=HELP_PENDING;
                                    help_seq_n=next_seq_n-16'd1;
                                end
                            end else enqueue(5,EXPRESSION,1,call_number,selected_card,0);
                            if(accept_n[5]) begin last_card_n=selected_card; last_valid_n=1; end
                        end
                    end
                    default: begin end // K4/K5 are handled above.
                endcase
            end
        end
        // Patient UI and touch use explicit frozen fields, never synthetic K6/K7.
        if(request_valid && request_ready) begin
            request_done_n=1;
            request_origin=request_kind==3 ? 3'd5:request_kind==6 ? 3'd7:3'd6;
            if(key_press[request_origin]) request_result_n=4;
            else if(request_kind==6) begin
                if(TICKET_MODE==0 || issued_number==20) request_result_n=1;
                else begin issued_n=issued_number+1'b1;accept_n[7]=1;request_accept_n=1;end
            end else if(request_kind==2) begin
                if(request_number==0 || request_number>call_number || request_number>20) request_result_n=1;
                else if(replay_exists(request_number)) request_result_n=2;
                else begin
                    // the touch screen replays the latest call; its room is last_room
                    enqueue(6,REPLAY,request_source,request_number,{1'b0,last_room},0);
                    request_accept_n=accept_n[6];
                    if(!accept_n[6]) request_result_n=3;
                end
            end else if(request_kind==3 && request_card==0) begin   // help (cards 1..5 removed 10/25)
                selected_n=request_card;
                if(pending_once_n[5] || (request_card==0 && help_state==HELP_PENDING)) request_result_n=2;
                else begin
                    enqueue(5,HELP,request_source,call_number,0,next_seq_n);
                    if(accept_n[5]) begin help_state_n=HELP_PENDING;help_seq_n=next_seq_n-16'd1;end
                    request_accept_n=accept_n[5];
                    if(accept_n[5]) begin last_card_n=request_card;last_valid_n=1;end
                    else request_result_n=3;
                end
            end else request_result_n=1;
            if(!request_accept_n) case(request_result_n)
                1:invalid_n[request_origin]=1;
                2:duplicate_n[request_origin]=1;
                3:begin full_n[request_origin]=1;overflow_n=1;end
                4:conflict_n[request_origin]=1;
                default:;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if(rst) begin
            call_number<=0; issued_number<=0; selected_card<=0; last_card<=0; last_card_valid<=0;
            help_state<=HELP_IDLE; help_seq<=0; next_seq<=1;
            queued_events<=0; busy<=0; active_seq<=0; active_key<=0; pending_once<=0; pending_replay<=0;
            accepted_keys<=0; reject_invalid<=0; reject_duplicate<=0;
            reject_full<=0; reject_conflict<=0;
            overflow_sticky<=0; completion_error_sticky<=0;
            request_done<=0;request_accepted<=0;request_result<=0;
            history1<=0;history2<=0;history3<=0;active_event<=0;
            room_numbers<=0; last_room<=0; help_room<=0;
            for(q=0;q<QDEPTH;q=q+1) queue[q]<=0;
        end else begin
            call_number<=number_n; issued_number<=issued_n; selected_card<=selected_n;
            request_done<=request_done_n;request_accepted<=request_accept_n;request_result<=request_result_n;
            if(accept_n[0]) begin history3<=history2;history2<=history1;history1<=call_number;end
            active_event<=active_event_n;
            room_numbers<=room_numbers_n & ~(20'hFFFFF << (5*ROOMS)); last_room<=last_room_n; help_room<=help_room_n;
            last_card<=last_card_n; last_card_valid<=last_valid_n;
            help_state<=help_state_n; help_seq<=help_seq_n; next_seq<=next_seq_n;
            queued_events<=queued_n; busy<=busy_n; active_seq<=active_seq_n;
            active_key<=active_key_n; pending_once<=pending_once_n; pending_replay<=pending_replay_n;
            accepted_keys<=accept_n; reject_invalid<=invalid_n; reject_duplicate<=duplicate_n;
            reject_full<=full_n; reject_conflict<=conflict_n;
            overflow_sticky<=overflow_n; completion_error_sticky<=completion_error_n;
            for(q=0;q<QDEPTH;q=q+1) queue[q]<=queue_n[q];
        end
    end
endmodule
