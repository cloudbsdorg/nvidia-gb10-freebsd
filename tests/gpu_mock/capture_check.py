import json, sys

cap = json.load(open(sys.argv[1]))
model = json.load(open(sys.argv[2]))
dev = cap['devices'][0]
card = model['cards'][0]
board = [b for b in model['boards'] if b['name'] == card['board']][0]
base = [b for b in model['bases'] if b['name'] == board['base']][0]

def want(name, got, exp):
    if got != exp:
        print("FAIL %s: the model says %r, the capture says %r" % (name, got, exp))
        sys.exit(1)

want("the uuid", card['uuid'], dev['identity']['uuid']['value'])
want("the pci bus", card['pci']['bus'], dev['identity']['pci_bus']['value'])
want("the pci slot", card['pci']['slot'], dev['identity']['pci_slot']['value'])
want("the vendor id", int(card['vendor_id'], 16), dev['identity']['pci_vendor']['value'])
want("the device id", int(card['device_id'], 16), dev['identity']['pci_device']['value'])
want("the subsystem vendor id", int(card['subsystem_vendor_id'], 16),
     dev['identity']['pci_subsystem_vendor']['value'])
want("the subsystem device id", int(card['subsystem_device_id'], 16),
     dev['identity']['pci_subsystem_device']['value'])
want("the revision", int(card['revision'], 16), dev['identity']['pci_revision']['value'])
want("the rm gpu id", card['rm_gpu_id'], dev['identity']['rm_gpu_id']['value'])
want("the architecture", base['architecture'], dev['gpu']['architecture']['value'])
want("the implementation", base['implementation'], dev['gpu']['implementation']['value'])
want("the chip id", base['chip_id'], dev['gpu']['chip_id']['value'])
want("the sm version major", base['sm_version']['major'],
     dev['gpu']['sm_version_major']['value'])
want("the sm version minor", base['sm_version']['minor'],
     dev['gpu']['sm_version_minor']['value'])
want("the gpc count", base['gpc_count'], dev['gpu']['gpc_count']['value'])
want("the tpc count", base['tpc_count'], dev['gpu']['tpc_count']['value'])
want("the classes", base['classes'], dev['gpu']['classes']['value'])
want("the vram size", board['vram_bytes'], dev['memory']['vram_size']['value'])
want("the bar1 size", board['bar1_bytes'], dev['memory']['bar1_size']['value'])
want("the max page size", base['max_page_size'],
     dev['memory']['max_page_size']['value'])
want("the page sizes", base['page_sizes'], dev['memory']['page_sizes']['value'])
want("the display capability", base['capabilities']['display_enabled'],
     [c['value'] for c in dev['capabilities'] if c['name'] == 'display_enabled'][0])
print("ok the model of the RTX 5060 Ti matches the capture")
