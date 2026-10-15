param(
    [ValidateRange(15,790)][int]$StartAx25 = 15,
    [ValidateRange(15,790)][int]$EndAx25 = 256,
    [ValidateRange(1,10)][int]$Repeats = 1,
    [ValidateRange(250,30000)][int]$GapMs = 4000,
    [ValidateRange(20,500)][int]$ChunkDelayMs = 80,
    [string]$WorkDir = "C:\PocketCHIRP-TDH9-BYTE-SWEEP"
)

if ($StartAx25 -gt $EndAx25) { throw "StartAx25 must not exceed EndAx25" }

$ErrorActionPreference = "Stop"

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
using System.IO;
using System.Text;
using System.Threading.Tasks;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

var AF00 = Guid.Parse("0000af00-0000-1000-8000-00805f9b34fb");
var AF01 = Guid.Parse("0000af01-0000-1000-8000-00805f9b34fb");

if (args.Length != 6) throw new ArgumentException("Expected start, end, repeats, gap, chunk delay, workdir");
int start = int.Parse(args[0]);
int end = int.Parse(args[1]);
int repeats = int.Parse(args[2]);
int gapMs = int.Parse(args[3]);
int chunkDelayMs = int.Parse(args[4]);
string outputDir = args[5];
if (start < 15 || end > 790 || end < start || repeats < 1) throw new ArgumentException("Invalid sweep range");


byte[] Header = {
    0xC0, 0x00,
    0xAE,0x8E,0x6A,0x8A,0x8A,0x96,0xE4,
    0xAE,0x8E,0x6A,0x8A,0x8A,0x96,0x63,
    0x3F
};

string Hex(byte[] b) => BitConverter.ToString(b).Replace("-", " ");
string Now() => DateTime.Now.ToString("HH:mm:ss.fff");

string Mac(ulong a) => string.Join(":",
    Enumerable.Range(0, 6)
        .Select(i => ((a >> ((5-i)*8)) & 0xff).ToString("X2")));

async Task<ulong> ChooseRadio()
{
    var watcher = new BluetoothLEAdvertisementWatcher {
        ScanningMode = BluetoothLEScanningMode.Active
    };

    var found = new Dictionary<ulong,(string Name,short Rssi)>();
    object gate = new();

    watcher.Received += (s,e) =>
    {
        string n = e.Advertisement.LocalName ?? "";
        if (!n.Contains("TD-H9", StringComparison.OrdinalIgnoreCase))
            return;

        lock (gate)
            found[e.BluetoothAddress] = (n,e.RawSignalStrengthInDBm);
    };

    Console.WriteLine("Scanning for TD-H9 radios...");
    watcher.Start();
    await Task.Delay(8000);
    watcher.Stop();

    List<KeyValuePair<ulong,(string Name,short Rssi)>> radios;
    lock(gate)
        radios = found.OrderByDescending(x=>x.Value.Rssi).ToList();

    if (radios.Count == 0)
        throw new Exception("No TD-H9 BLE radios found.");

    for (int i=0; i<radios.Count; i++)
        Console.WriteLine(
            $"  [{i+1}] {radios[i].Value.Name} {Mac(radios[i].Key)} RSSI {radios[i].Value.Rssi}");

    while (true)
    {
        Console.Write("Select TX radio: ");
        if (int.TryParse(Console.ReadLine(), out int n) &&
            n >= 1 && n <= radios.Count)
            return radios[n-1].Key;
    }
}

byte[] MakeFrame(int ax25Len)
{
    int extra = ax25Len - 15;
    var data = new List<byte>(Header);
    if (extra <= 4) {
        // Preserve the exact existing test bytes for 15, 16, 17, 18, 19.
        for (int i = 0; i < extra; ++i)
            data.Add((byte)(0x50 + extra));
    } else {
        // The main radio may replace the first post-control byte with 00.
        // Encode the intended AX.25 length in the NEXT TWO bytes so a
        // shortened receive record can still reveal the test length.
        // 0x21..0x60 avoids KISS C0/DB and HDLC 7E/7F/1B.
        data.Add(0x53);
        data.Add((byte)(0x21 + (ax25Len & 63)));
        data.Add((byte)(0x21 + ((ax25Len >> 6) & 63)));
        for (int i = 3; i < extra; ++i)
            data.Add((byte)(0x30 + ((ax25Len * 7 + i * 11) % 60)));
    }
    data.Add(0xC0);
    if (data.Count != ax25Len + 3)
        throw new InvalidOperationException("KISS/AX.25 length mismatch");
    return data.ToArray();
}

async Task WriteFrame(GattCharacteristic tx, byte[] frame)
{
    for (int off=0; off<frame.Length; off+=20)
    {
        int len = Math.Min(20, frame.Length-off);
        byte[] part = new byte[len];
        System.Buffer.BlockCopy(frame, off, part, 0, len);

        using var dw = new DataWriter();
        dw.WriteBytes(part);

        var status = await tx.WriteValueAsync(
            dw.DetachBuffer(),
            GattWriteOption.WriteWithoutResponse);

        if (status != GattCommunicationStatus.Success)
            throw new Exception($"AF01 write failed at offset {off}, size {len}: {status}");
        if (off + len < frame.Length) await Task.Delay(chunkDelayMs);
    }
}

Console.WriteLine("TD-H9 SABM ONE-BYTE INCREMENTAL LENGTH SWEEP");
Console.WriteLine("=======================================");
Console.WriteLine();
Console.WriteLine($"Lengths: {start}..{end} AX.25 bytes, one byte at a time");
Console.WriteLine($"Repeats per length: {repeats}, gap: {gapMs} ms, BLE chunk delay: {chunkDelayMs} ms");
Console.WriteLine("Uses installed TX firmware; no radio firmware changes required.");
Console.WriteLine("Starts with the exact 15/16/17/18/19-byte frames used in earlier tests.");
Console.WriteLine("These are diagnostic SABM-shaped bytes, not standard connected-mode traffic.");
Console.WriteLine("For 20+ bytes, the two bytes following the first extra byte encode the TX length.");
Console.WriteLine("A BLE Success only means the Windows write was accepted; it does NOT prove RF delivery.");
Console.WriteLine();

ulong addr = await ChooseRadio();

using BluetoothLEDevice? dev =
    await BluetoothLEDevice.FromBluetoothAddressAsync(addr);

if (dev is null)
    throw new Exception("Unable to open TX radio.");

var sr = await dev.GetGattServicesForUuidAsync(
    AF00, BluetoothCacheMode.Uncached);

if (sr.Status != GattCommunicationStatus.Success ||
    sr.Services.Count == 0)
    throw new Exception("AF00 service unavailable.");

var cr = await sr.Services[0].GetCharacteristicsForUuidAsync(
    AF01, BluetoothCacheMode.Uncached);

if (cr.Status != GattCommunicationStatus.Success ||
    cr.Characteristics.Count == 0)
    throw new Exception("AF01 characteristic unavailable.");

var tx = cr.Characteristics[0];

Console.WriteLine();
Directory.CreateDirectory(outputDir);
string logPath = Path.Combine(outputDir, "TDH9-SABM-BYTE-SWEEP-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".csv");
using var log = new StreamWriter(logPath, false, new UTF8Encoding(false));
log.WriteLine("Timestamp,Test,Repeat,Ax25Bytes,ExtraBytes,KissWireBytes,BleChunks,Marker,ExactWireHex,Status");
log.Flush();

Console.WriteLine("TX log: " + logPath);
Console.WriteLine("Start the direct AF02 PS1 on the OTHER TD-H9 now; leave APRS ON.");
Console.WriteLine("Press ENTER to begin sending, or Ctrl+C to stop.");
Console.ReadLine();

int total = (end - start + 1) * repeats;
int test = 0;
for (int ax25Len = start; ax25Len <= end; ++ax25Len)
{
    byte[] frame = MakeFrame(ax25Len);
    int extra = ax25Len - 15;
    string marker = extra == 0 ? "(none)" :
        extra <= 4 ? Hex(Enumerable.Repeat((byte)(0x50 + extra), extra)) :
        $"53 {frame[18]:X2} {frame[19]:X2} (encodes length {ax25Len})";
    int chunks = (frame.Length + 19) / 20;
    for (int rep = 1; rep <= repeats; ++rep)
    {
        ++test;
        string at = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff");
        Console.WriteLine();
        Console.WriteLine($"[{at}] TEST {test}/{total} AX25={ax25Len} B | KISS={frame.Length} B | AF01 chunks={chunks} | rep={rep}/{repeats}");
        Console.WriteLine("  Marker: " + marker);
        Console.WriteLine("  First bytes: " + Hex(frame.Take(Math.Min(28,frame.Length))));
        if (frame.Length > 28)
            Console.WriteLine("  Last bytes:  ... " + Hex(frame.Skip(frame.Length-12)));
        string status = "BLE_ACCEPTED";
        try { await WriteFrame(tx, frame); }
        catch (Exception e) { status = "BLE_FAILED: " + e.Message; }
        string csvHex = Hex(frame).Replace(" ", "");
        log.WriteLine($"{at},{test},{rep},{ax25Len},{extra},{frame.Length},{chunks},{marker.Replace(' ', '_')},{csvHex},{status.Replace(',', ';')}");
        log.Flush();
        Console.WriteLine("  AF01: " + status);
        if (status != "BLE_ACCEPTED") {
            Console.WriteLine("Stopping on AF01 failure; resume with -StartAx25.");
            Console.WriteLine("TX CSV: " + logPath);
            return;
        }
        await Task.Delay(gapMs);
    }
}
Console.WriteLine();
Console.WriteLine("SWEEP COMPLETE. TX CSV: " + logPath);
Console.WriteLine("Please send me the first RX output and any length where reception changes.");
Console.WriteLine("Press ENTER to exit.");
Console.ReadLine();
'@

Set-Content -Path (Join-Path $WorkDir "TDH9-F-RF-Length-ID-Sweep.csproj") -Value $csproj -Encoding UTF8
Set-Content -Path (Join-Path $WorkDir "Program.cs") -Value $program -Encoding UTF8

& dotnet run --project (Join-Path $WorkDir "TDH9-F-RF-Length-ID-Sweep.csproj") -- $StartAx25 $EndAx25 $Repeats $GapMs $ChunkDelayMs $WorkDir
if ($LASTEXITCODE -ne 0) { throw "Length-sweep app exited with code $LASTEXITCODE" }