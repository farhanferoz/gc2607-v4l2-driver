obj-m := ipu-bridge.o

KDIR ?= /usr/src/kernels/7.0.11-200.fc44.x86_64

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean
