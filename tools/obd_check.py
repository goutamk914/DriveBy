import sys

import obd

conn = obd.OBD(sys.argv[1] if len(sys.argv) > 1 else None)
if not conn.is_connected():
    raise SystemExit("not connected — ignition on? adapter paired?")
print("protocol:", conn.protocol_name())
for cmd in (obd.commands.RPM, obd.commands.SPEED, obd.commands.MAF, obd.commands.FUEL_RATE):
    supported = conn.supports(cmd)
    value = conn.query(cmd).value if supported else None
    print(f"{cmd.command.decode():>6}  {cmd.name:<12} supported={supported!s:<5} value={value}")
print("\nFuel per trip: FUEL_RATE (015E) if supported, else MAF (0110): fuel g/s = MAF/14.7, gallons = g/2830.")
