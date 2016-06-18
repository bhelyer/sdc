module d.sync.parking;

enum ParkResult {
	Barging,
	Direct,
}

struct ParkingLot {
	ParkResult compareAndPark(T)(Atomic!T* var, T expected) shared {
		return ParkResult.Barging;
	}
}

shared ParkingLot parkingLot;
