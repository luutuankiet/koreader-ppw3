#!/usr/bin/env python3
# Pull Worker and Durable Object usage for kindle-gateway-worker from Cloudflare GraphQL analytics.
#   analytics.py <start ISO> <end ISO>   (needs CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID)
import json, os, sys, urllib.request
start, end = sys.argv[1], sys.argv[2]
acct = os.environ['CLOUDFLARE_ACCOUNT_ID']
q = """query($a: String!, $s: Time!, $e: Time!) { viewer { accounts(filter: {accountTag: $a}) {
  workers: workersInvocationsAdaptive(limit: 100, filter: {scriptName: "kindle-gateway-worker", datetime_geq: $s, datetime_leq: $e}) {
    sum { requests errors subrequests } quantiles { cpuTimeP50 cpuTimeP99 } dimensions { status } }
  doInv: durableObjectsInvocationsAdaptiveGroups(limit: 100, filter: {datetime_geq: $s, datetime_leq: $e}) {
    sum { requests } dimensions { scriptName status } }
  doPeriodic: durableObjectsPeriodicGroups(limit: 100, filter: {datetime_geq: $s, datetime_leq: $e}) {
    sum { activeTime cpuTime duration inboundWebsocketMsgCount outboundWebsocketMsgCount subrequests exceededCpuErrors }
    max { activeWebsocketConnections } dimensions { namespaceId } }
} } }"""
req = urllib.request.Request('https://api.cloudflare.com/client/v4/graphql',
    data=json.dumps({'query': q, 'variables': {'a': acct, 's': start, 'e': end}}).encode(),
    headers={'Authorization': 'Bearer ' + os.environ['CLOUDFLARE_API_TOKEN'], 'Content-Type': 'application/json'})
print(json.dumps(json.load(urllib.request.urlopen(req)), indent=1))
