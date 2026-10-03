"""A bounded, isolated RAOP test. No global output, library or credential writes."""
import asyncio
from ipaddress import IPv4Address
import logging
import sys

import pyatv
from pyatv.conf import AppleTV, ManualService
from pyatv.const import Protocol


async def main():
    config = AppleTV(IPv4Address("192.168.0.11"), "X100 diagnostic")
    config.add_service(ManualService("83D8052413DC", Protocol.RAOP, 5000, {
        "cn": "0,1", "et": "0,1", "ch": "2", "sr": "44100", "ss": "16",
        "am": "ShairportSync", "pw": "false", "tp": "TCP,UDP",
    }))
    atv = await pyatv.connect(config, asyncio.get_running_loop())
    try:
        await atv.audio.set_volume(12)
        print("RAOP direct streaming, volume 12%, maximum 12 seconds", flush=True)
        try:
            await asyncio.wait_for(atv.stream.stream_file(sys.argv[1]), timeout=12)
        except TimeoutError:
            print("Probe time limit reached", flush=True)
    finally:
        tasks = atv.close()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)


if __name__ == "__main__":
    logging.basicConfig(level=logging.DEBUG, format="%(asctime)s %(name)s %(message)s")
    asyncio.run(main())
