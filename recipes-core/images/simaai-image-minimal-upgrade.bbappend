require recipes-core/images/ark-compatible-machine.inc

require recipes-core/images/ark-image.inc

# SiMa upgrade recipe expands update_${MACHINE}.sh / sw-description_${MACHINE}.
# ARK carriers inherit MACHINEOVERRIDES "modalix:" — reuse Modalix SWU assets.
UPDATE_FILE:modalix = "update_modalix.sh"
SW_FILE:modalix = "sw-description_modalix"
