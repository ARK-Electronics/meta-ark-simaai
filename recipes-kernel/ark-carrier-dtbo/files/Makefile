DTSO := $(wildcard *.dtso)
NAMES := $(basename $(DTSO))

DTC ?= dtc
DTC_FLAGS ?= -@ -I dts -O dtb

all:
	@for name in $(NAMES); do \
		echo "DTC $$name.dtbo"; \
		$(DTC) $(DTC_FLAGS) -o $$name.dtbo $$name.dtso; \
	done

clean:
	rm -f *.dtbo
