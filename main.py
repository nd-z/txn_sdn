#!/usr/bin/env python2
import argparse
import grpc
import json
import os
import Queue
import socket
import sys
import threading
from time import sleep
from scapy.all import sniff, sendp, send, get_if_list, get_if_hwaddr, srp1, sr1, bind_layers
from scapy.all import Packet
from scapy.all import Ether, IP, UDP, TCP, IntField, StrFixedLenField, XByteField, ShortField, BitField

from controller import TransactionManager

sys.path.append(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'utils/'))
import run_exercise
import p4runtime_lib.bmv2
from p4runtime_lib.switch import ShutdownAllSwitchConnections
import p4runtime_lib.helper

switches = {}
p4info_helper = None

class Runner(threading.Thread):
    def __init__(self, txn_mgr, txn_id, config_json):
        super(Runner, self).__init__()
        self.txn_mgr = txn_mgr
        self.txn_id = txn_id
        self.config_json = config_json

    def run(self):
        self.txn_mgr.run_txn(self.txn_id, self.config_json)


def addForwardingRule(switch, table_name, match_fields, action_name, action_params):
    global p4info_helper, switches
    # Helper function to install forwarding rules
    table_entry = p4info_helper.buildTableEntry(
        table_name=table_name,
        match_fields=match_fields,
        action_name=action_name,
        action_params=action_params)
    bmv2_switch = switches[switch]
    try:
        bmv2_switch.WriteTableEntry(table_entry)
        print "Installed rule on %s" % (switch)
    except Exception as e:
        print e
        print "CONTROLLER %s: Problem with installing rule on %s" % (str(self.txn_mgr), switch)

def main(p4info_file_path, bmv2_file_path, topo_file_path, sw_config_file_path, controller_id):
    # Instantiate a P4Runtime helper from the p4info file
    global p4info_helper
    p4info_helper = p4runtime_lib.helper.P4InfoHelper(p4info_file_path)
    
    try:
        # Establish a P4 Runtime connection to each switch
        for switch in ["s1", "s2", "s3"]:
            switch_id = int(switch[1:])
            bmv2_switch = p4runtime_lib.bmv2.Bmv2SwitchConnection(
                name=switch,
                address="127.0.0.1:%d" % (50050 + switch_id),
                device_id=(switch_id - 1),
                proto_dump_file="logs/%s-p4runtime-requests.txt" % switch)            
            bmv2_switch.MasterArbitrationUpdate()
            print "Established as controller for %s" % bmv2_switch.name

            bmv2_switch.SetForwardingPipelineConfig(p4info=p4info_helper.p4info,
                                                    bmv2_json_file_path=bmv2_file_path)
            print "Installed P4 Program using SetForwardingPipelineConfig on %s" % bmv2_switch.name
            switches[switch] = bmv2_switch

        f = open('sw.config')
        f2 = open('sw2.config')
        sw_config_json = json.load(f)
        sw_config_json2 = json.load(f2)
        
        # main thread pulls from queue to add forwarding rule
        main_q = Queue.Queue()

        txn_mgr = TransactionManager(1, switches, main_q, Queue.Queue())
        txn_mgr2 = TransactionManager(2, switches, main_q, Queue.Queue())

        runner1 = Runner(txn_mgr, 1, sw_config_json)
        runner2 = Runner(txn_mgr2, 2, sw_config_json2)
        runner2.start()
        runner1.start()
        while True:
            t = main_q.get()
            main_q_ack = t[0]
            txn_params = t[1]
            for param in txn_params:
                addForwardingRule(param[0], param[1], param[2], param[3], param[4])
            main_q_ack.put("ack")

    except KeyboardInterrupt:
        print " Shutting down."
    except grpc.RpcError as e:
        print "gRPC Error:", e.details(),
        status_code = e.code()
        print "(%s)" % status_code.name,
        traceback = sys.exc_info()[2]
        print "[%s:%d]" % (traceback.tb_frame.f_code.co_filename, traceback.tb_lineno)

    ShutdownAllSwitchConnections()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='P4Runtime Controller')
    parser.add_argument('--p4info', help='p4info proto in text format from p4c',
                        type=str, action="store", required=False,
                        default='./build/switch.p4.p4info.txt')
    parser.add_argument('--bmv2-json', help='BMv2 JSON file from p4c',
                        type=str, action="store", required=False,
                        default='./build/switch.json')
    parser.add_argument('--topo', help='Topology file',
                        type=str, action="store", required=False,
                        default='topology.json')
    parser.add_argument('--sw_config', help='New configuration for switches', type=str, action="store", required=False, default='sw.config')
    parser.add_argument('--id', help='Controller id', type=int, action="store", required=False, default=0)
    args = parser.parse_args()

    if not os.path.exists(args.p4info):
        parser.print_help()
        print "\np4info file not found: %s\nHave you run 'make'?" % args.p4info
        parser.exit(1)
    if not os.path.exists(args.bmv2_json):
        parser.print_help()
        print "\nBMv2 JSON file not found: %s\nHave you run 'make'?" % args.bmv2_json
        parser.exit(1)
    if not os.path.exists(args.topo):
        parser.print_help()
        print "\nTopology file not found: %s" % args.topo
        parser.exit(1)
    if not os.path.exists(args.sw_config):
        parser.print_help()
        print "\nSwitch config file not found: %s" % args.sw_config
        parser.exit(1)

    main(args.p4info, args.bmv2_json, args.topo, args.sw_config, args.id)
