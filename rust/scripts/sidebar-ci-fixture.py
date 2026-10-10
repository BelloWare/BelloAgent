#!/usr/bin/env python3
"""Own only newly created synthetic CI fixtures; never repair existing permissions/ACLs."""
import argparse
import errno
import json
import os
import pathlib
import shutil
import stat
import tempfile

MARKER = '.bello-agent-ci-fixture.json'
# GitHub's Ubuntu image runs `chmod -R 777 /opt` (runner-images
# images/ubuntu/scripts/build/configure-system.sh), which the ancestor policy
# below rightly rejects. Use a dedicated root-owned 0755 parent instead.
CI_PARENT = pathlib.Path('/bello-agent-ci')
ATTRIBUTES = ('system.posix_acl_access', 'system.posix_acl_default')


def validate(fd, uid, private=False):
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode) or info.st_uid not in ({uid} if private else {0, uid}):
        raise ValueError('fixture ancestor owner/type rejected')
    mode = stat.S_IMODE(info.st_mode)
    if (private and mode != 0o700) or (not private and mode & 0o022):
        raise ValueError('fixture ancestor permissions rejected')
    for attribute in ATTRIBUTES:
        for attempt in range(3):
            try:
                value = os.getxattr(fd, attribute)
            except OSError as error:
                if error.errno in (errno.ENODATA, errno.ENOTSUP):
                    break
                if error.errno == errno.EINTR and attempt < 2:
                    continue
                raise
            raise ValueError(f'fixture ancestor ACL rejected: {attribute}, bytes={len(value)}')


def open_directory(path, uid, private=False):
    path = pathlib.Path(path)
    if not path.is_absolute() or str(path) != os.path.realpath(path) or '..' in path.parts:
        raise ValueError('fixture path is not canonical absolute')
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        validate(fd, uid)
        for index, part in enumerate(path.parts[1:]):
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            os.close(fd)
            fd = child
            validate(fd, uid, private and index == len(path.parts) - 2)
        return fd
    except BaseException:
        os.close(fd)
        raise


def provenance(uid, gid, run_id, attempt):
    if not run_id.isdecimal() or not attempt.isdecimal() or uid < 0 or gid < 0:
        raise ValueError('invalid fixture provenance')
    return dict(schema=1, purpose='bello-agent-synthetic-ci', uid=uid, gid=gid,
                run_id=run_id, attempt=attempt)


def create(parent, uid, gid, run_id, attempt):
    record = provenance(uid, gid, run_id, attempt)
    parent_fd = open_directory(parent, uid)
    root = None
    created_identity = None
    try:
        if not shutil.rmtree.avoids_symlink_attacks:
            raise ValueError('descriptor-safe cleanup unavailable')
        # mkdtemp uses exclusive mkdir and 0700, never an existing directory.
        root = pathlib.Path(tempfile.mkdtemp(prefix=f'bello-agent-ci-{run_id}-{attempt}-', dir=parent))
        info = os.stat(root.name, dir_fd=parent_fd, follow_symlinks=False)
        created_identity = (info.st_dev, info.st_ino)
        fd = os.open(root.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
        try:
            validate(fd, os.geteuid(), True)
            marker = os.open(MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600, dir_fd=fd)
            try:
                payload = json.dumps(record, sort_keys=True).encode()
                if os.write(marker, payload) != len(payload):
                    raise OSError('short fixture provenance write')
                os.fsync(marker)
                # These descriptors were exclusively created by this invocation.
                os.fchown(marker, uid, gid)
            finally:
                os.close(marker)
            os.fchown(fd, uid, gid)
            os.fsync(fd)
        finally:
            os.close(fd)
        return root
    except BaseException:
        # Only the directory exclusively created by this call can be removed here.
        if root is not None and created_identity is not None:
            info = os.stat(root.name, dir_fd=parent_fd, follow_symlinks=False)
            if (info.st_dev, info.st_ino) == created_identity:
                shutil.rmtree(root.name, dir_fd=parent_fd)
        raise
    finally:
        os.close(parent_fd)


def ensure_ci_parent(uid):
    """Create the CI parent exclusively as root; an existing one must pass the same checks."""
    if os.geteuid() != 0:
        raise ValueError('CI fixture parent creation requires root')
    try:
        os.mkdir(CI_PARENT, 0o755)
        os.chmod(CI_PARENT, 0o755)  # Only the directory this call just created.
    except FileExistsError:
        pass
    os.close(open_directory(CI_PARENT, uid))
    return CI_PARENT


def cleanup(root, uid, gid, run_id, attempt):
    root = pathlib.Path(root)
    expected = provenance(uid, gid, run_id, attempt)
    if not root.name.startswith(f'bello-agent-ci-{run_id}-{attempt}-'):
        raise ValueError('fixture basename/provenance rejected')
    parent_fd = open_directory(root.parent, uid)
    try:
        fd = os.open(root.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent_fd)
        try:
            validate(fd, uid, True)
            marker = os.open(MARKER, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd)
            try:
                info = os.fstat(marker)
                if not stat.S_ISREG(info.st_mode) or info.st_uid != uid or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 4096:
                    raise ValueError('fixture marker metadata rejected')
                found = json.loads(os.read(marker, 4097))
            finally:
                os.close(marker)
            if found != expected:
                raise ValueError('fixture marker provenance rejected')
            actual = os.stat(root.name, dir_fd=parent_fd, follow_symlinks=False)
            held = os.fstat(fd)
            if (actual.st_dev, actual.st_ino) != (held.st_dev, held.st_ino):
                raise ValueError('fixture changed before cleanup')
            if not shutil.rmtree.avoids_symlink_attacks:
                raise ValueError('descriptor-safe cleanup unavailable')
            shutil.rmtree(root.name, dir_fd=parent_fd)
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)


def self_test(parent):
    uid, gid = os.getuid(), os.getgid()
    from unittest.mock import patch
    before = set(pathlib.Path(parent).iterdir())
    with patch.object(os, 'fchown', side_effect=OSError('injected ownership setup failure')):
        try:
            create(parent, uid, gid, '122', '1')
        except OSError:
            pass
        else:
            raise AssertionError('injected creation failure did not fail')
    assert set(pathlib.Path(parent).iterdir()) == before
    root = create(parent, uid, gid, '123', '1')
    sibling = create(parent, uid, gid, '123', '1')
    assert root != sibling and stat.S_IMODE(root.stat().st_mode) == 0o700
    outside = sibling / 'preserved'
    outside.write_text('synthetic preserve')
    (root / 'link').symlink_to(sibling, target_is_directory=True)
    for args in [(root, uid, gid, '123', '2'), (sibling, uid, gid, '123', '2')]:
        try:
            cleanup(*args)
        except ValueError:
            pass
        else:
            raise AssertionError('wrong provenance was accepted')
    marker = root / MARKER
    original = marker.read_bytes()
    marker.write_text('{}')
    try:
        cleanup(root, uid, gid, '123', '1')
    except ValueError as error:
        assert 'marker provenance' in str(error)
    else:
        raise AssertionError('invalid marker was accepted')
    assert root.is_dir() and outside.read_text() == 'synthetic preserve'
    marker.unlink()
    os.mkfifo(marker, 0o600)
    try:
        cleanup(root, uid, gid, '123', '1')
    except ValueError as error:
        assert 'marker metadata' in str(error)
    else:
        raise AssertionError('nonregular marker was accepted')
    marker.unlink()
    with marker.open('xb') as stream:
        stream.write(original)
    marker.chmod(0o600)  # Only the recreated test marker is changed.
    cleanup(root, uid, gid, '123', '1')
    assert outside.read_text() == 'synthetic preserve'
    unsafe = sibling / 'unsafe'
    unsafe.mkdir(mode=0o777)
    unsafe.chmod(0o777)  # Only this test-created directory is changed.
    try:
        open_directory(unsafe, uid)
    except ValueError:
        pass
    else:
        raise AssertionError('unsafe ancestor was accepted')
    import struct
    acl_directory = sibling / 'actual-default-acl'
    acl_directory.mkdir(mode=0o700)
    # Linux's documented POSIX ACL xattr format; only this new test dir changes.
    acl = struct.pack('<I', 2) + b''.join(struct.pack('<HHI', tag, perm, 0xffffffff)
                                         for tag, perm in ((1, 7), (4, 0), (32, 0)))
    os.setxattr(acl_directory, 'system.posix_acl_default', acl)
    try:
        open_directory(acl_directory, uid)
    except ValueError as error:
        assert 'system.posix_acl_default' in str(error)
    else:
        raise AssertionError('real default ACL was accepted')
    alias = sibling / 'alias'
    alias.symlink_to(parent, target_is_directory=True)
    try:
        open_directory(alias, uid)
    except ValueError:
        pass
    else:
        raise AssertionError('aliased ancestor was accepted')
    cleanup(sibling, uid, gid, '123', '1')
    print('fixture exclusive creation/provenance/unsafe ancestry/symlink-safe cleanup controls passed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('create', 'cleanup', 'self-test'))
    parser.add_argument('--uid', type=int)
    parser.add_argument('--gid', type=int)
    parser.add_argument('--run-id')
    parser.add_argument('--attempt')
    parser.add_argument('--root')
    parser.add_argument('--test-parent')
    args = parser.parse_args()
    if args.action == 'self-test':
        self_test(pathlib.Path(args.test_parent or os.getcwd()))
        return
    if None in (args.uid, args.gid, args.run_id, args.attempt):
        parser.error('explicit uid/gid/run/attempt required')
    if args.action == 'create':
        print(create(ensure_ci_parent(args.uid), args.uid, args.gid, args.run_id, args.attempt))
    else:
        if not args.root or pathlib.Path(args.root).parent != CI_PARENT:
            parser.error(f'cleanup root must be the created {CI_PARENT} fixture')
        cleanup(pathlib.Path(args.root), args.uid, args.gid, args.run_id, args.attempt)
        try:
            os.rmdir(CI_PARENT)  # Only when empty; another fixture keeps it.
        except OSError:
            pass


if __name__ == '__main__':
    main()
