"""Loopback-only framed datagram relay for an authorized SSH port forward.
No payload, destination, key or URL logging. One UDP flow per TCP connection.
"""
import argparse
import asyncio
import struct

MAX_PACKET = 65535

async def read_frame(reader):
    length = struct.unpack("!I", await reader.readexactly(4))[0]
    if not 0 < length <= MAX_PACKET:
        raise ValueError("invalid frame length")
    return await reader.readexactly(length)

class OracleUDP(asyncio.DatagramProtocol):
    def __init__(self, writer):
        self.writer = writer
    def datagram_received(self, data, addr):
        if len(data) <= MAX_PACKET:
            self.writer.write(struct.pack("!I", len(data)) + data)

async def oracle_client(reader, writer, port):
    loop = asyncio.get_running_loop()
    transport = None
    try:
        transport, _ = await loop.create_datagram_endpoint(lambda: OracleUDP(writer), remote_addr=("127.0.0.1", port))
        while True:
            transport.sendto(await read_frame(reader))
            await writer.drain()
    except (asyncio.IncompleteReadError, ConnectionError, OSError, ValueError):
        pass
    finally:
        if transport:
            transport.close()
        writer.close()
        await writer.wait_closed()

class MacUDP(asyncio.DatagramProtocol):
    def __init__(self, tcp_port):
        self.tcp_port=tcp_port
        self.transport=None
        self.peer=None
        self.queue=asyncio.Queue(maxsize=512)
    def connection_made(self, transport):
        self.transport=transport
    def datagram_received(self, data, addr):
        if self.peer is None:
            self.peer=addr
        if addr != self.peer:
            return
        try:
            self.queue.put_nowait(data)
        except asyncio.QueueFull:
            pass
    async def run(self):
        while True:
            writer=None
            try:
                reader,writer=await asyncio.open_connection("127.0.0.1",self.tcp_port)
                async def tx():
                    while True:
                        data=await self.queue.get()
                        writer.write(struct.pack("!I",len(data))+data)
                        await writer.drain()
                async def rx():
                    while True:
                        data=await read_frame(reader)
                        if self.peer is not None:
                            self.transport.sendto(data,self.peer)
                jobs=[asyncio.create_task(tx()),asyncio.create_task(rx())]
                done,pending=await asyncio.wait(jobs,return_when=asyncio.FIRST_COMPLETED)
                for job in pending: job.cancel()
                for job in done: job.result()
            except (asyncio.IncompleteReadError,ConnectionError,OSError,ValueError):
                await asyncio.sleep(1)
            finally:
                if writer:
                    writer.close()
                    await writer.wait_closed()

async def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("mode",choices=("oracle","mac"))
    parser.add_argument("--tcp-port",type=int,default=18522)
    parser.add_argument("--udp-port",type=int,default=18521)
    args=parser.parse_args()
    if args.mode=="oracle":
        server=await asyncio.start_server(lambda r,w: oracle_client(r,w,args.udp_port),"127.0.0.1",args.tcp_port)
        async with server:
            await server.serve_forever()
    else:
        loop=asyncio.get_running_loop()
        transport,protocol=await loop.create_datagram_endpoint(lambda:MacUDP(args.tcp_port),local_addr=("127.0.0.1",args.udp_port))
        try: await protocol.run()
        finally: transport.close()

if __name__=="__main__":
    asyncio.run(main())
