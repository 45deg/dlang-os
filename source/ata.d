/// QEMU PCのプライマリIDEマスターをATA PIOで操作する。1回の転送は512バイト。
module ata;

import clock : milliseconds;

import cpu : readPort, writePort, readPortWord, writePortWord;

enum sectorBytes = 512;
alias Sector = ushort[sectorBytes / ushort.sizeof];

private enum ushort dataPort = 0x1f0;
private enum ushort sectorCountPort = 0x1f2;
private enum ushort lbaLowPort = 0x1f3;
private enum ushort lbaMidPort = 0x1f4;
private enum ushort lbaHighPort = 0x1f5;
private enum ushort drivePort = 0x1f6;
private enum ushort statusPort = 0x1f7; // 書き込み時はコマンドレジスタ
private enum ushort controlPort = 0x3f6; // 読み出し時は代替ステータス
private enum ubyte busy = 0x80;
private enum ubyte ready = 0x40;
private enum ubyte dataReady = 0x08;
private enum ubyte deviceFaultOrError = 0x21;

nothrow @nogc:

bool initDisk()
{
    writePort(controlPort, 0x02); // nIEN: 割り込みを使わずステータスを確認する
    writePort(drivePort, 0xe0);
    settle();
    return waitStatus(ready, dataReady, false);
}

bool readSector(uint lba, out Sector sector)
{
    if (!issueTransfer(lba, 0x20))
        return false;

    foreach (ref word; sector)
        word = readPortWord(dataPort);
    settle();
    return waitStatus(ready, dataReady);
}

bool writeSector(uint lba, ref const Sector sector)
{
    if (!issueTransfer(lba, 0x30))
        return false;

    foreach (word; sector)
        writePortWord(dataPort, word);
    settle();
    if (!waitStatus(ready, dataReady))
        return false;

    writePort(statusPort, 0xe7); // FLUSH CACHEが終わってから保存成功を返す
    settle();
    return waitStatus(ready, dataReady);
}

private bool issueTransfer(uint lba, ubyte command)
{
    if (lba > 0x0fffffff || !waitStatus(ready, dataReady, false))
        return false;

    writePort(drivePort, cast(ubyte) (0xe0 | (lba >> 24)));
    settle();
    writePort(sectorCountPort, 1);
    writePort(lbaLowPort, cast(ubyte) lba);
    writePort(lbaMidPort, cast(ubyte) (lba >> 8));
    writePort(lbaHighPort, cast(ubyte) (lba >> 16));
    writePort(statusPort, command);
    settle();
    return waitStatus(dataReady, 0);
}

private void settle()
{
    foreach (_; 0 .. 4)
        readPort(controlPort);
}

private bool waitStatus(ubyte required, ubyte forbidden, bool checkErrors = true)
{
    const started = milliseconds();
    while (milliseconds() - started < 100)
    {
        const status = readPort(controlPort);
        if (status == 0 || status == 0xff)
            return false;
        if (status & busy)
            continue;
        if (checkErrors && (status & deviceFaultOrError))
            return false;
        if ((status & required) == required && (status & forbidden) == 0)
            return true;
    }
    return false;
}
