/* -*- P4_16 -*- */
#include <core.p4>
#include <v1model.p4>

const bit<16> TYPE_TWOPC_PHASE = 0x9999;
const bit<8> TYPE_VOTE = 0;
const bit<8> TYPE_CONFIRM = 1;
const bit<8> TYPE_RELEASE = 2;
const bit<8> TYPE_COMMIT = 3;
const bit<8> TYPE_FINISHED = 4;
const bit<8> TYPE_FREE = 5;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<9>  egressSpec_t;
typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;
typedef bit<9>  switch_port_t;

#define MAX_CHANGES 10
const bit<16>        TYPE_IPV4 = 0x800;
const switch_port_t  CONTROLLER_PORT = 255;


header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

/* BEGIN TXN_SDN HEADERS */

/* mgr --> switch */

/* vote request from txn mgr */
header vote_t {
    bit<32>    txn_mgr;
    bit<32>    txn_id;
}

/* vote reply to txn mgr */
header confirm_t {
    bit<32>    txn_mgr;
    bit<32>    txn_id;
    bit<8>    status; // 0 for success
}

/* txn mgr telling us to release the lock if we hold it for them */
header release_t {
    bit<32>    txn_mgr;
    bit<32>    txn_id;
}

/* commit reply from txn mgr: basically telling us to release the lock but only on successful txn */
header commit_t {
    bit<32>    txn_mgr;
    bit<32>    txn_id;
}

/* commit ack to txn mgr */
header finished_t {
    bit<32>    txn_mgr;
    bit<32>    txn_id;
}

/* response to abort */
header free_t {
    bit<32>    txn_mgr;
    bit<32>    txn_id;
}

header twopc_phase_t {
    bit<8>  phase;
}

header_union twopc_t {
    vote_t          vote;
    commit_t        commit;
    confirm_t       confirm;
    release_t       release;
    finished_t      finished;
    free_t          free;
}

struct metadata {
    /* empty */
}

struct headers {
    ethernet_t          ethernet;
    ipv4_t              ipv4;
    twopc_phase_t       twopc_phase;
    twopc_t             twopc;
    // packet_in_header_t  packet_in;
    // packet_out_header_t packet_out;
}

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser MyParser(packet_in packet,
                out headers hdr,
                inout metadata meta,
                inout standard_metadata_t standard_metadata) {

    state start {
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_TWOPC_PHASE: parse_twopc_phase;
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition accept;
    }

    state parse_twopc_phase {
        packet.extract(hdr.twopc_phase);
        transition select(hdr.twopc_phase.phase) {
            TYPE_VOTE: parse_twopc_vote;
            TYPE_RELEASE: parse_twopc_release;
            TYPE_COMMIT: parse_twopc_commit;
            default: accept;
        }
    }

    state parse_twopc_vote {
        packet.extract(hdr.twopc.vote);
        transition accept;
    }
    state parse_twopc_release {
        packet.extract(hdr.twopc.release);
        transition accept;
    }
    state parse_twopc_commit {
        packet.extract(hdr.twopc.commit);
        transition accept;
    }

}

/*************************************************************************
************   C H E C K S U M    V E R I F I C A T I O N   *************
*************************************************************************/

control MyVerifyChecksum(inout headers hdr, inout metadata meta) {   
    apply {  }
}


/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyIngress(inout headers hdr,
                  inout metadata meta,
                  inout standard_metadata_t standard_metadata) {

    register<bit<32>>(1) lock_txn_mgr;
    register<bit<32>>(1) lock_txn_id;
    action send_to_controller() {
        standard_metadata.egress_spec = standard_metadata.ingress_port;
        // hdr.packet_in.setValid();
        // hdr.packet_in.ingress_port = standard_metadata.ingress_port;
    }

    action drop() {
        mark_to_drop(standard_metadata);
    }

    action finish() {
        lock_txn_mgr.write(32w0, 0);
        lock_txn_mgr.write(32w0, 0);
        hdr.twopc.finished.setValid();
        hdr.twopc_phase.phase = TYPE_FINISHED;
        hdr.twopc.finished.txn_mgr = hdr.twopc.commit.txn_mgr;
        hdr.twopc.finished.txn_id = hdr.twopc.commit.txn_id;
        hdr.twopc.commit.setInvalid();
        send_to_controller();
    }
    
    action abort() {
        hdr.twopc.free.setValid();
        hdr.twopc_phase.phase = TYPE_FREE; 
        hdr.twopc.free.txn_mgr = hdr.twopc.release.txn_mgr;
        hdr.twopc.free.txn_id = hdr.twopc.release.txn_id;
        hdr.twopc.release.setInvalid();
        send_to_controller();
    }

    table debug {
        key = {
            hdr.twopc.vote.txn_id: exact;
            hdr.twopc.vote.txn_mgr: exact;
        }
        actions = {
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }

    action ipv4_forward(egressSpec_t port) {
        standard_metadata.egress_spec = port;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = NoAction();
    }
    
    apply {
        // Process only IPv4 packets.   
        if (hdr.ipv4.isValid()) {
            ipv4_lpm.apply();

        } else if (hdr.twopc.vote.isValid()) {
            debug.apply();
            bit<32> mgr = 0;
            bit<32> id = 0;
            lock_txn_mgr.read(mgr, 0);
            lock_txn_id.read(id, 0);
            hdr.twopc_phase.phase = TYPE_CONFIRM;
            hdr.twopc.confirm.setValid();
            hdr.twopc.confirm.txn_mgr = hdr.twopc.vote.txn_mgr;
            hdr.twopc.confirm.txn_id = hdr.twopc.vote.txn_id;
            hdr.twopc.vote.setInvalid();
            if (mgr == 0) {
                lock_txn_mgr.write(32w0, hdr.twopc.vote.txn_mgr);
                lock_txn_id.write(32w0, hdr.twopc.vote.txn_id);
                hdr.twopc.confirm.status = 0;
            }
            else {
                // same thing except set confirm.status = 0 and send to cntrlr
                hdr.twopc.confirm.status = 1;
            }
            bit<48> temp = hdr.ethernet.dstAddr;
            hdr.ethernet.dstAddr = hdr.ethernet.srcAddr;
            hdr.ethernet.srcAddr = temp;
            hdr.ethernet.etherType = 0x9999;
            send_to_controller();
        }
        else if (hdr.twopc.commit.isValid()) {
            bit<48> temp = hdr.ethernet.dstAddr;
            hdr.ethernet.dstAddr = hdr.ethernet.srcAddr;
            hdr.ethernet.srcAddr = temp;
            hdr.ethernet.etherType = 0x9999;
            finish();
        }
        else if (hdr.twopc.release.isValid()) {
            bit<48> temp = hdr.ethernet.dstAddr;
            hdr.ethernet.dstAddr = hdr.ethernet.srcAddr;
            hdr.ethernet.srcAddr = temp;
            hdr.ethernet.etherType = 0x9999;

            bit<32> mgr = 0;
            bit<32> id = 0;
            lock_txn_mgr.read(mgr, 0);
            lock_txn_id.read(id, 0);

            if (hdr.twopc.release.txn_mgr == mgr && hdr.twopc.release.txn_id == id) {
                lock_txn_mgr.write(32w0, 0);
                lock_txn_mgr.write(32w0, 0);
            }
            abort();
        }
        else {
            drop();
        }
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control MyEgress(inout headers hdr,
                 inout metadata meta,
                 inout standard_metadata_t standard_metadata) {
    apply {  }
}

/*************************************************************************
*************   C H E C K S U M    C O M P U T A T I O N   **************
*************************************************************************/

control MyComputeChecksum(inout headers  hdr, inout metadata meta) {
     apply {
    update_checksum(
        hdr.ipv4.isValid(),
            { hdr.ipv4.version,
          hdr.ipv4.ihl,
              hdr.ipv4.diffserv,
              hdr.ipv4.totalLen,
              hdr.ipv4.identification,
              hdr.ipv4.flags,
              hdr.ipv4.fragOffset,
              hdr.ipv4.ttl,
              hdr.ipv4.protocol,
              hdr.ipv4.srcAddr,
              hdr.ipv4.dstAddr },
            hdr.ipv4.hdrChecksum,
            HashAlgorithm.csum16);
    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control MyDeparser(packet_out packet, in headers hdr) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.twopc_phase);
        packet.emit(hdr.twopc);
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

V1Switch(
MyParser(),
MyVerifyChecksum(),
MyIngress(),
MyEgress(),
MyComputeChecksum(),
MyDeparser()
) main;
