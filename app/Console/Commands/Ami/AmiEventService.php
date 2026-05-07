<?php

namespace App\Console\Commands\Ami;

use AsteriskPbxManager\Events\CallConnected;
use AsteriskPbxManager\Facades\AsteriskManager;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Event;
use Illuminate\Support\Facades\Log;
use PAMI\Message\Event\EventMessage;

class AmiEventService extends Command
{
    protected $signature = 'ami:service';
    protected $description = 'Connect to Asterisk AMI and stream events into Laravel.';

    public function handle(): int
    {
        // 1. Establish (or reuse) the AMI connection.
        try {
            $connected = AsteriskManager::isConnected() || AsteriskManager::connect();
        } catch (\Throwable $e) {
            $this->error("Connection error: {$e->getMessage()}");
            return self::FAILURE;
        }

        if (! $connected) {
            $this->error('Failed to connect to Asterisk AMI.');
            return self::FAILURE;
        }

        // 2. Subscribe via the package's documented API. Every parsed AMI
        //    event flows through this callback.
        AsteriskManager::addEventListener(function (EventMessage $event) {
            $name = $event->getName();
            $keys = $event->getKeys();

            Log::info('AMI event', ['name' => $name, 'keys' => $keys]);
            $this->line('['.$name.'] '.json_encode($keys));
        });

        // 3. The package also dispatches its own Laravel events for common
        //    AMI events. Keep this so existing app listeners still fire.
        Event::listen(CallConnected::class, function (CallConnected $event) {
            Log::info('Call connected', [
                'unique_id' => $event->uniqueId ?? null,
                'channel'   => $event->channel ?? null,
                'caller_id' => $event->callerId ?? null,
            ]);
        });

        // 4. Locate the underlying PAMI client. The facade doesn't expose
        //    process()/listen(), but PAMI's ClientImpl always does — and it
        //    is the thing that actually reads frames off the AMI socket.
        $client = $this->resolvePamiClient(app('asterisk-manager'));
        if (! $client) {
            $this->error(
                'Could not locate the underlying PAMI client. '
                .'Run `php artisan tinker` and inspect '
                .'get_class_methods(app(\'asterisk-manager\')) to find the accessor.'
            );
            return self::FAILURE;
        }

        // 5. Graceful shutdown on Ctrl-C / SIGTERM.
        $running = true;
        if (function_exists('pcntl_async_signals')) {
            pcntl_async_signals(true);
            pcntl_signal(SIGINT,  function () use (&$running) { $running = false; });
            pcntl_signal(SIGTERM, function () use (&$running) { $running = false; });
        }

        $this->info('Connected to Asterisk AMI. Listening for events... (Ctrl-C to quit)');

        // 6. The actual event loop. process() reads any pending frames from
        //    the socket and dispatches each to every registered listener.
        while ($running) {
            try {
                $client->process();
            } catch (\Throwable $e) {
                Log::warning('AMI process() failed', ['error' => $e->getMessage()]);
                // Try to reconnect; back off briefly to avoid a tight loop.
                sleep(1);
                try {
                    AsteriskManager::reconnect();
                } catch (\Throwable $reconnectError) {
                    Log::error('AMI reconnect failed', ['error' => $reconnectError->getMessage()]);
                }
            }

            usleep(50_000); // 50 ms — keep CPU usage near zero.
        }

        $this->info('Shutting down.');
        AsteriskManager::disconnect();

        return self::SUCCESS;
    }

    /**
     * Find the wrapped PAMI client. Tries common accessors first, then
     * falls back to reflecting over the service's properties so this works
     * regardless of how the package exposes (or hides) the client.
     */
    private function resolvePamiClient(object $service): ?object
    {
        foreach (['getClient', 'getPamiClient', 'getConnection'] as $method) {
            if (method_exists($service, $method)) {
                $candidate = $service->{$method}();
                if (is_object($candidate) && method_exists($candidate, 'process')) {
                    return $candidate;
                }
            }
        }

        $ref = new \ReflectionObject($service);
        foreach ($ref->getProperties() as $prop) {
            $prop->setAccessible(true);
            $value = $prop->getValue($service);
            if (is_object($value) && method_exists($value, 'process')) {
                return $value;
            }
        }

        return null;
    }
}
