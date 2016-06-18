module d.sync.lock;

import sdc.intrinsics;

struct Lock {
private:
	import d.sync.atomic;
	Atomic!ubyte val;

	enum LockBit = 0x01;
	enum ParkBit = 0x02;
	enum Mask = LockBit | ParkBit;

public:
	void lock() {
		// No operation done after the lock is taken can be reordered before.
		ubyte expected = 0;
		if (likely(val.casWeak(expected, LockBit, MemoryOrder.Acquire))) {
			return;
		}

		lockSlow();
	}

	void unlock() {
		// No operation done before the lock is freed can be reordered after.
		ubyte expected = LockBit;
		if (likely(val.casWeak(expected, 0, MemoryOrder.Release))) {
			return;
		}

		unlockSlow();
	}

private:
	void lockSlow() {
		// Trusting WTF::Lock on that one...
		enum SpinLimit = 40;

		uint spinCount = 0;

		while (true) {
			auto current = val.load();

			// If the lock if free, we try to barge in.
			if (!(current & LockBit)) {
				if (val.casWeak(current, current | LockBit)) {
					// We got the lock, VICTORY !
					return;
				}
				
				continue;
			}

			// If nobody's parked...
			if (!(current & ParkBit)) {
				// First, try to spin a bit.
				if (spinCount < SpinLimit) {
					spinCount++;
					// FIXME: shed_yield();
					continue;
				}

				// We've waited long enough, let's try to park.
				if (!val.casWeak(current, current | ParkBit)) {
					continue;
				}
			}

			assert(current & LockBit, "Lock not held!");
			assert(current & ParkBit, "Lock not parked!");

			// Alright, let's park.
			import d.sync.parking;
			autp pr = parkingLot.compareAndPark!ubyte(&var, current);
			if (pr == ParkResult.Barging) {
				// The lock was released, or we failed to park,
				// either way just loop around.
				continue;
			}

			assert(pr == ParkResult.Direct, "Unexpected handover!");
			assert(current & LockBit, "Lock not held!");
			
			// This is a direct handover. The lock was never released, the
			// thread which used to own it did not unlock it.
			// We are done.
			return;
		}
	}

	void unlockSlow() {
		while (true) {
			auto current = val.load();

			// If nobody is parked, just unlock.
			if (current == LockBit) {
				if (val.casWeak(current, 0)) {
					return;
				}

				continue;
			}

			assert(current & LockBit, "Lock not held!");
			assert(current & ParkBit, "Lock not parked!");

			/+
			// FIXME: We may be able to get this from the CAS operations
			// if we get intrinsics right.
			auto b = val.load();
			assert(b | LockBit, "Lock is not locked");


			// As it turns out, someone is parked, free them.
			assert(b == LockBit | ParkBit, "Unexpected lock value");
			/+
			ParkingLot::unparkOne(&val, (result) {
				assert(val.load() == LockBit | ParkBit, "Unexpected lock value");
				val.store(result.moar ? ParkBit : 0);
			});
			// +/
			assert(0, "Parkign not supported");

			// At this point, we should be free to go.
			// return;
			// +/
		}
	}
}
