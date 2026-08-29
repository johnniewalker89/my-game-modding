using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using SCModLauncher;

var payload = Enumerable.Range(0, 256 * 1024)
    .Select(index => (byte)(index % 251))
    .ToArray();
var root = Path.Combine(Path.GetTempPath(), "sc-mod-launcher-transport-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);

try
{
    await VerifyRetryRecoveryAsync(root, payload);
    await VerifyRetryExhaustionAsync(root, payload);
    await VerifySizeMismatchAsync(root, payload);
    Console.WriteLine("Update transport tests passed.");
    return 0;
}
finally
{
    Directory.Delete(root, recursive: true);
}

static async Task VerifyRetryRecoveryAsync(string root, byte[] payload)
{
    using var handler = new ScriptedHandler(payload, failuresBeforeSuccess: 2);
    using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    var destination = Path.Combine(root, "recovered.zip");
    var log = new List<string>();

    await UpdatePackageDownloader.DownloadAsync(
        client,
        "https://example.test/release.zip",
        destination,
        payload.LongLength,
        log.Add,
        delayAsync: (_, _) => Task.CompletedTask);

    Assert(handler.Attempts == 3, "Downloader should recover on the third attempt.");
    Assert(File.ReadAllBytes(destination).SequenceEqual(payload), "Recovered file must match the payload.");
    Assert(!File.Exists(destination + ".part"), "Successful download must not leave a partial file.");
    Assert(log.Count == 3, "Two retries and final recovery should be logged.");
}

static async Task VerifyRetryExhaustionAsync(string root, byte[] payload)
{
    using var handler = new ScriptedHandler(payload, failuresBeforeSuccess: int.MaxValue);
    using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    var destination = Path.Combine(root, "failed.zip");

    try
    {
        await UpdatePackageDownloader.DownloadAsync(
            client,
            "https://example.test/release.zip",
            destination,
            payload.LongLength,
            maxAttempts: 3,
            delayAsync: (_, _) => Task.CompletedTask);
        throw new InvalidOperationException("Expected retry exhaustion was not raised.");
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("после 3 попыток", StringComparison.Ordinal))
    {
    }

    Assert(handler.Attempts == 3, "Downloader must stop after three failed attempts.");
    Assert(!File.Exists(destination), "Failed download must not replace the destination.");
    Assert(!File.Exists(destination + ".part"), "Failed download must remove its partial file.");
}

static async Task VerifySizeMismatchAsync(string root, byte[] payload)
{
    using var handler = new ScriptedHandler(payload, failuresBeforeSuccess: 0);
    using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };
    var destination = Path.Combine(root, "wrong-size.zip");

    try
    {
        await UpdatePackageDownloader.DownloadAsync(
            client,
            "https://example.test/release.zip",
            destination,
            payload.LongLength + 1,
            maxAttempts: 3,
            delayAsync: (_, _) => Task.CompletedTask);
        throw new InvalidOperationException("Expected size mismatch was not raised.");
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("после 3 попыток", StringComparison.Ordinal))
    {
    }

    Assert(handler.Attempts == 3, "Size mismatch should use the bounded retry policy.");
    Assert(!File.Exists(destination), "Wrong-size response must not replace the destination.");
    Assert(!File.Exists(destination + ".part"), "Wrong-size response must remove its partial file.");
}

static void Assert(bool condition, string message)
{
    if (!condition)
    {
        throw new InvalidOperationException("ASSERT FAILED: " + message);
    }
}

sealed class ScriptedHandler(byte[] payload, int failuresBeforeSuccess) : HttpMessageHandler
{
    public int Attempts { get; private set; }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Attempts++;
        HttpContent content = Attempts <= failuresBeforeSuccess
            ? new InterruptedContent(payload)
            : new ByteArrayContent(payload);
        content.Headers.ContentLength = payload.LongLength;

        return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        {
            RequestMessage = request,
            Content = content
        });
    }
}

sealed class InterruptedContent(byte[] payload) : HttpContent
{
    protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
    {
        await stream.WriteAsync(payload.AsMemory(0, payload.Length / 2));
        throw new IOException("simulated unexpected EOF");
    }

    protected override bool TryComputeLength(out long length)
    {
        length = payload.LongLength;
        return true;
    }
}
