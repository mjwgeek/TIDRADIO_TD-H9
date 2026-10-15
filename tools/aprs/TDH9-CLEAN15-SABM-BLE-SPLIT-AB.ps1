param(
    [string]$WorkDir = "C:\PocketCHIRP-TDH9-SABM-SPLIT-AB"
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "TD-H9 CLEAN SABM BLE FRAGMENTATION A/B TEST" -ForegroundColor Cyan
Write-Host "================================"
Write-Host ""
Write-Host "Compares one vs two BLE writes with the same exact clean KISS frame:"
Write-Host "  Destination: WG5EEK-2"
Write-Host "  Source:      WG5EEK-1"
Write-Host "  Control:     0x3F (SABM(P))"
Write-Host "  AX.25 length: 15 bytes"
Write-Host "  No PID"
Write-Host "  No information bytes"
Write-Host ""

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET 8 SDK was not found."
}

New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$csproj = @'
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
  </PropertyGroup>
</Project>
'@

$program = @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

var AF00 = Guid.Parse("0000af00-0000-1000-8000-00805f9b34fb");
var AF01 = Guid.Parse("0000af01-0000-1000-8000-00805f9b34fb");

string Hex(IEnumerable<byte> b) =>
    string.Join(" ", b.Select(x => x.ToString("X2")));

string Mac(ulong a) =>
    string.Join(":", Enumerable.Range(0, 6)
        .Select(i => ((a >> ((5 - i) * 8)) & 0xFF).ToString("X2")));

async Task<ulong> ChooseRadioAsync()
{
    var watcher = new BluetoothLEAdvertisementWatcher {
        ScanningMode = BluetoothLEScanningMode.Active
    };

    var found = new Dictionary<ulong,(string Name,short Rssi)>();
    object gate = new();

    watcher.Received += (s,e) =>
    {
        string name = e.Advertisement.LocalName ?? "";
        if (!name.Contains("TD-H9", StringComparison.OrdinalIgnoreCase))
            return;

        lock (gate)
            found[e.BluetoothAddress] = (name, e.RawSignalStrengthInDBm);
    };

    Console.WriteLine("Scanning for TD-H9 radios...");
    watcher.Start();
    await Task.Delay(8000);
    watcher.Stop();

    List<KeyValuePair<ulong,(string Name,short Rssi)>> radios;
    lock (gate)
        radios = found.OrderByDescending(x => x.Value.Rssi).ToList();

    if (radios.Count == 0)
        throw new Exception("No TD-H9 BLE radios found.");

    Console.WriteLine();
    for (int i = 0; i < radios.Count; i++)
        Console.WriteLine(
            $"  [{i + 1}] {radios[i].Value.Name,-22} {Mac(radios[i].Key)} RSSI {radios[i].Value.Rssi}");

    while (true)
    {
        Console.Write("Select TX radio: ");
        string? s = Console.ReadLine();
        if (int.TryParse(s, out int n) && n >= 1 && n <= radios.Count)
            return radios[n - 1].Key;

        Console.WriteLine("Invalid selection.");
    }
}

// KISS wire frame:
//   C0       FEND
//   00       KISS DATA, port 0
//   15-byte AX.25 SABM(P):
//     AE 8E 6A 8A 8A 96 E4   WG5EEK-2
//     AE 8E 6A 8A 8A 96 63   WG5EEK-1
//     3F                     SABM(P)
//   C0       FEND
//
// Total BLE payload = 18 bytes.
// AX.25 payload inside KISS = exactly 15 bytes.
byte[] frame = {
    0xC0, 0x00,
    0xAE,0x8E,0x6A,0x8A,0x8A,0x96,0xE4,
    0xAE,0x8E,0x6A,0x8A,0x8A,0x96,0x63,
    0x3F,
    0xC0
};

Console.WriteLine();
Console.WriteLine("Logical KISS frame:");
Console.WriteLine("  " + Hex(frame));
Console.WriteLine();
Console.WriteLine($"BLE write length : {frame.Length} bytes");
Console.WriteLine("AX.25 data length: 15 bytes");
Console.WriteLine("Expected AX.25 end: ... 96 63 3F");
Console.WriteLine();

ulong addr = await ChooseRadioAsync();

using BluetoothLEDevice? dev =
    await BluetoothLEDevice.FromBluetoothAddressAsync(addr);

if (dev is null)
    throw new Exception("Unable to open selected TD-H9.");

var services = await dev.GetGattServicesForUuidAsync(
    AF00, BluetoothCacheMode.Uncached);

if (services.Status != GattCommunicationStatus.Success ||
    services.Services.Count == 0)
    throw new Exception("AF00 service unavailable.");

var chars = await services.Services[0].GetCharacteristicsForUuidAsync(
    AF01, BluetoothCacheMode.Uncached);

if (chars.Status != GattCommunicationStatus.Success ||
    chars.Characteristics.Count == 0)
    throw new Exception("AF01 characteristic unavailable.");

var tx = chars.Characteristics[0];

Console.WriteLine();
Console.WriteLine("Start the RX AF02 receiver on the OTHER radio.");
Console.WriteLine("Press ENTER for the controlled A/B/C tests...");
Console.ReadLine();

async Task SendChunks(string label, byte[] data, int[] sizes)
{
    Console.WriteLine();
    Console.WriteLine("========================================================");
    Console.WriteLine(label);
    Console.WriteLine($"KISS bytes: {data.Length}  AX.25 bytes: {data.Length - 3}");
    Console.WriteLine("Frame: " + Hex(data));
    Console.WriteLine("========================================================");
    int offset = 0;
    foreach (int n in sizes)
    {
        if (n <= 0 || offset + n > data.Length)
            throw new ArgumentException("Invalid chunk lengths");
        byte[] chunk = data.Skip(offset).Take(n).ToArray();
        using var dw = new DataWriter();
        dw.WriteBytes(chunk);
        var status = await tx.WriteValueAsync(
            dw.DetachBuffer(), GattWriteOption.WriteWithoutResponse);
        Console.WriteLine($"  AF01 write {n} B: {Hex(chunk)} -> {status}");
        if (status != GattCommunicationStatus.Success)
            throw new Exception("AF01 write failed: " + status);
        offset += n;
        if (offset < data.Length) await Task.Delay(80);
    }
    if (offset != data.Length) throw new Exception("Frame not completely sent");
    Console.WriteLine("SENT. Watch TX key/audio and RX AF02 RAW data.");
    await Task.Delay(5000);
}

// Clean AX.25 SABM is the SAME EXACT 15 bytes in cases A and B.
// Only BLE fragmentation changes. No PID, no padding, no extra RF bytes.
if (frame.Length != 18 || frame[16] != 0x3F || frame[17] != 0xC0)
    throw new Exception("Unexpected clean SABM baseline");

// The previously decoded 18-byte AX.25 input: 3F 53 53 53,
// wire length 21 B, sent as normal 20+1 BLE writes. Only a control case.
byte[] reference = frame.Take(frame.Length - 1)
                        .Concat(new byte[] { 0x53, 0x53, 0x53, 0xC0 })
                        .ToArray();
if (reference.Length != 21)
    throw new Exception("Unexpected reference frame length");

await SendChunks("CASE A: CLEAN 15-byte SABM; ONE 18-byte AF01 write", frame,
                 new int[] {18});
await SendChunks("CASE B: SAME CLEAN 15-byte SABM; TWO AF01 writes 17+1", frame,
                 new int[] {17, 1});
await SendChunks("CASE C: KNOWN LONGER 18-byte AX.25 control; TWO AF01 writes 20+1",
                 reference, new int[] {20, 1});

Console.WriteLine();
Console.WriteLine("ALL THREE TESTS FINISHED.");
Console.WriteLine("A vs B isolates BLE write fragmentation with IDENTICAL RF AX.25 bytes.");
Console.WriteLine("C confirms whether known longer SABM still works in this setup.");
Console.WriteLine("An AF01 Success means Windows accepted the BLE write, not RF success.");
Console.WriteLine("Please report whether TX keyed and RX showed an AF02 packet for A/B/C.");
Console.WriteLine("Press ENTER to exit.");
Console.ReadLine();
'@

Set-Content -Path (Join-Path $WorkDir "TDH9-SABM-Split-AB.csproj") -Value $csproj -Encoding UTF8
Set-Content -Path (Join-Path $WorkDir "Program.cs") -Value $program -Encoding UTF8

dotnet run --project (Join-Path $WorkDir "TDH9-SABM-Split-AB.csproj")