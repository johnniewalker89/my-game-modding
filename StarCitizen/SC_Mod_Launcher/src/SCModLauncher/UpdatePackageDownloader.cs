using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace SCModLauncher;

internal static class UpdatePackageDownloader
{
    private const int DefaultMaxAttempts = 3;
    private const int CopyBufferSize = 128 * 1024;

    internal static async Task DownloadAsync(
        HttpClient client,
        string downloadUrl,
        string destinationPath,
        long expectedSize,
        Action<string>? log = null,
        int maxAttempts = DefaultMaxAttempts,
        Func<TimeSpan, CancellationToken, Task>? delayAsync = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(client);
        ArgumentException.ThrowIfNullOrWhiteSpace(downloadUrl);
        ArgumentException.ThrowIfNullOrWhiteSpace(destinationPath);
        ArgumentOutOfRangeException.ThrowIfNegative(expectedSize);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxAttempts, 1);

        delayAsync ??= Task.Delay;
        var partialPath = destinationPath + ".part";

        for (var attempt = 1; attempt <= maxAttempts; attempt++)
        {
            DeletePartialFile(partialPath);

            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, downloadUrl)
                {
                    Version = HttpVersion.Version11,
                    VersionPolicy = HttpVersionPolicy.RequestVersionExact
                };
                using var response = await client.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken);
                response.EnsureSuccessStatusCode();

                var responseSize = response.Content.Headers.ContentLength;
                if (expectedSize > 0 && responseSize.HasValue && responseSize.Value != expectedSize)
                {
                    throw new IOException(
                        $"GitHub сообщил размер {responseSize.Value}, ожидалось {expectedSize} байт.");
                }

                await using var source = await response.Content.ReadAsStreamAsync(cancellationToken);
                await using var destination = new FileStream(
                    partialPath,
                    FileMode.Create,
                    FileAccess.Write,
                    FileShare.None,
                    CopyBufferSize,
                    FileOptions.Asynchronous | FileOptions.SequentialScan);
                await source.CopyToAsync(destination, CopyBufferSize, cancellationToken);
                await destination.FlushAsync(cancellationToken);

                var actualSize = destination.Length;
                if (expectedSize > 0 && actualSize != expectedSize)
                {
                    throw new IOException(
                        $"Скачано {actualSize} из ожидаемых {expectedSize} байт.");
                }

                if (responseSize.HasValue && actualSize != responseSize.Value)
                {
                    throw new IOException(
                        $"Скачано {actualSize} из объявленных сервером {responseSize.Value} байт.");
                }

                destination.Close();
                File.Move(partialPath, destinationPath, overwrite: true);
                if (attempt > 1)
                {
                    log?.Invoke($"Обновления: загрузка завершена с попытки {attempt} из {maxAttempts}.");
                }
                return;
            }
            catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
            {
                DeletePartialFile(partialPath);
                if (!IsTransient(ex))
                {
                    throw;
                }

                if (attempt == maxAttempts)
                {
                    throw new InvalidOperationException(
                        $"Скачивание оборвалось после {maxAttempts} попыток: {RootMessage(ex)}");
                }

                log?.Invoke(
                    $"Обновления: попытка {attempt} из {maxAttempts} оборвалась: " +
                    $"{RootMessage(ex)} Повторяю загрузку.");
                await delayAsync(TimeSpan.FromSeconds(attempt * 2), cancellationToken);
            }
        }
    }

    private static bool IsTransient(Exception exception)
    {
        if (exception is IOException or TaskCanceledException)
        {
            return true;
        }

        if (exception is not HttpRequestException requestException)
        {
            return false;
        }

        return !requestException.StatusCode.HasValue ||
            requestException.StatusCode is HttpStatusCode.RequestTimeout or
                HttpStatusCode.TooManyRequests ||
            (int)requestException.StatusCode.Value >= 500;
    }

    private static string RootMessage(Exception exception)
    {
        var message = exception.GetBaseException().Message;
        return string.IsNullOrWhiteSpace(message) ? exception.Message : message;
    }

    private static void DeletePartialFile(string path)
    {
        if (File.Exists(path))
        {
            File.Delete(path);
        }
    }
}
