/*
  ==============================================================================

   This file is part of the JUCE library - "Jules' Utility Class Extensions"
   Copyright 2004-10 by Raw Material Software Ltd.

  ------------------------------------------------------------------------------

   JUCE can be redistributed and/or modified under the terms of the GNU General
   Public License (Version 2), as published by the Free Software Foundation.
   A copy of the license is included in the JUCE distribution, or can be found
   online at www.gnu.org/licenses.

   JUCE is distributed in the hope that it will be useful, but WITHOUT ANY
   WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
   A PARTICULAR PURPOSE.  See the GNU General Public License for more details.

  ------------------------------------------------------------------------------

   To release a closed-source product which uses JUCE, commercial licenses are
   available: visit www.rawmaterialsoftware.com/juce for more information.

  ==============================================================================
*/

// (This file gets included by juce_linux_NativeCode.cpp, rather than being
// compiled on its own).
#if JUCE_INCLUDED_FILE

enum
{
    U_ISOFS_SUPER_MAGIC = 0x9660,   // linux/iso_fs.h
    U_MSDOS_SUPER_MAGIC = 0x4d44,   // linux/msdos_fs.h
    U_NFS_SUPER_MAGIC = 0x6969,     // linux/nfs_fs.h
    U_SMB_SUPER_MAGIC = 0x517B      // linux/smb_fs.h
};

//==============================================================================
bool File::copyInternal (const File& dest) const
{
    FileInputStream in (*this);

    if (dest.deleteFile())
    {
        {
            FileOutputStream out (dest);

            if (out.failedToOpen())
                return false;

            if (out.writeFromInputStream (in, -1) == getSize())
                return true;
        }

        dest.deleteFile();
    }

    return false;
}

void File::findFileSystemRoots (Array<File>& destArray)
{
    destArray.add (File ("/"));
}

//==============================================================================
bool File::isOnCDRomDrive() const
{
    struct statfs buf;

    return statfs (getFullPathName().toUTF8(), &buf) == 0
             && buf.f_type == (short) U_ISOFS_SUPER_MAGIC;
}

bool File::isOnHardDisk() const
{
    struct statfs buf;

    if (statfs (getFullPathName().toUTF8(), &buf) == 0)
    {
        switch (buf.f_type)
        {
            case U_ISOFS_SUPER_MAGIC:   // CD-ROM
            case U_MSDOS_SUPER_MAGIC:   // Probably floppy (but could be mounted FAT filesystem)
            case U_NFS_SUPER_MAGIC:     // Network NFS
            case U_SMB_SUPER_MAGIC:     // Network Samba
                return false;

            default:
                // Assume anything else is a hard-disk (but note it could
                // be a RAM disk.  There isn't a good way of determining
                // this for sure)
                return true;
        }
    }

    // Assume so if this fails for some reason
    return true;
}

bool File::isOnRemovableDrive() const
{
    jassertfalse; // xxx not implemented for linux!
    return false;
}

bool File::isHidden() const
{
    return getFileName().startsWithChar ('.');
}

//==============================================================================
namespace
{
    const File juce_readlink (const String& file, const File& defaultFile)
    {
        const int size = 8192;
        HeapBlock<char> buffer;
        buffer.malloc (size + 4);

        const size_t numBytes = readlink (file.toUTF8(), buffer, size);

        if (numBytes > 0 && numBytes <= size)
            return File (file).getSiblingFile (String::fromUTF8 (buffer, (int) numBytes));

        return defaultFile;
    }
}

const File File::getLinkedTarget() const
{
    return juce_readlink (getFullPathName().toUTF8(), *this);
}

//==============================================================================
const char* juce_Argv0 = 0;  // referenced from juce_Application.cpp

const File File::getSpecialLocation (const SpecialLocationType type)
{
    switch (type)
    {
    case userHomeDirectory:
    {
        const char* homeDir = getenv ("HOME");

        if (homeDir == 0)
        {
            struct passwd* const pw = getpwuid (getuid());
            if (pw != 0)
                homeDir = pw->pw_dir;
        }

        return File (String::fromUTF8 (homeDir));
    }

    case userDocumentsDirectory:
    case userMusicDirectory:
    case userMoviesDirectory:
    case userApplicationDataDirectory:
        return File ("~");

    case userDesktopDirectory:
        return File ("~/Desktop");

    case commonApplicationDataDirectory:
        return File ("/var");

    case globalApplicationsDirectory:
        return File ("/usr");

    case tempDirectory:
    {
        File tmp ("/var/tmp");

        if (! tmp.isDirectory())
        {
            tmp = "/tmp";

            if (! tmp.isDirectory())
                tmp = File::getCurrentWorkingDirectory();
        }

        return tmp;
    }

    case invokedExecutableFile:
        if (juce_Argv0 != 0)
            return File (String::fromUTF8 (juce_Argv0));
        // deliberate fall-through...

    case currentExecutableFile:
    case currentApplicationFile:
        return juce_getExecutableFile();

    case hostApplicationPath:
        return juce_readlink ("/proc/self/exe", juce_getExecutableFile());

    default:
        jassertfalse; // unknown type?
        break;
    }

    return File::nonexistent;
}

//==============================================================================
const String File::getVersion() const
{
    return String::empty; // xxx not yet implemented
}

//==============================================================================
bool File::moveToTrash() const
{
    if (! exists())
        return true;

    File trashCan ("~/.Trash");

    if (! trashCan.isDirectory())
        trashCan = "~/.local/share/Trash/files";

    if (! trashCan.isDirectory())
        return false;

    return moveFileTo (trashCan.getNonexistentChildFile (getFileNameWithoutExtension(),
                                                         getFileExtension()));
}

//==============================================================================
class DirectoryIterator::NativeIterator::Pimpl
{
public:
    Pimpl (const File& directory, const String& wildCard_)
        : parentDir (File::addTrailingSeparator (directory.getFullPathName())),
          wildCard (wildCard_),
          dir (opendir (directory.getFullPathName().toUTF8()))
    {
        if (wildCard == "*.*")
            wildCard = "*";

        wildcardUTF8 = wildCard.toUTF8();
    }

    ~Pimpl()
    {
        if (dir != 0)
            closedir (dir);
    }

    bool next (String& filenameFound,
               bool* const isDir, bool* const isHidden, int64* const fileSize,
               Time* const modTime, Time* const creationTime, bool* const isReadOnly)
    {
        if (dir == 0)
            return false;

        for (;;)
        {
            struct dirent* const de = readdir (dir);

            if (de == 0)
                return false;

            if (fnmatch (wildcardUTF8, de->d_name, FNM_CASEFOLD) == 0)
            {
                filenameFound = String::fromUTF8 (de->d_name);
                const String path (parentDir + filenameFound);

                if (isDir != 0 || fileSize != 0 || modTime != 0 || creationTime != 0)
                {
                    struct stat info;
                    const bool statOk = juce_stat (path, info);

                    if (isDir != 0)         *isDir = statOk && ((info.st_mode & S_IFDIR) != 0);
                    if (fileSize != 0)      *fileSize = statOk ? info.st_size : 0;
                    if (modTime != 0)       *modTime = statOk ? (int64) info.st_mtime * 1000 : 0;
                    if (creationTime != 0)  *creationTime = statOk ? (int64) info.st_ctime * 1000 : 0;
                }

                if (isHidden != 0)
                    *isHidden = filenameFound.startsWithChar ('.');

                if (isReadOnly != 0)
                    *isReadOnly = access (path.toUTF8(), W_OK) != 0;

                return true;
            }
        }
    }

private:
    String parentDir, wildCard;
    const char* wildcardUTF8;
    DIR* dir;

    Pimpl (const Pimpl&);
    Pimpl& operator= (const Pimpl&);
};

DirectoryIterator::NativeIterator::NativeIterator (const File& directory, const String& wildCard)
    : pimpl (new DirectoryIterator::NativeIterator::Pimpl (directory, wildCard))
{
}

DirectoryIterator::NativeIterator::~NativeIterator()
{
}

bool DirectoryIterator::NativeIterator::next (String& filenameFound,
                                              bool* const isDir, bool* const isHidden, int64* const fileSize,
                                              Time* const modTime, Time* const creationTime, bool* const isReadOnly)
{
    return pimpl->next (filenameFound, isDir, isHidden, fileSize, modTime, creationTime, isReadOnly);
}


//==============================================================================
bool PlatformUtilities::openDocument (const String& fileName, const String& parameters)
{
    String cmdString (fileName.replace (" ", "\\ ",false));
    cmdString << " " << parameters;

    if (URL::isProbablyAWebsiteURL (fileName)
         || cmdString.startsWithIgnoreCase ("file:")
         || URL::isProbablyAnEmailAddress (fileName))
    {
        // create a command that tries to launch a bunch of likely browsers
        const char* const browserNames[] = { "xdg-open", "/etc/alternatives/x-www-browser", "firefox", "mozilla", "konqueror", "opera" };

        StringArray cmdLines;

        for (int i = 0; i < numElementsInArray (browserNames); ++i)
            cmdLines.add (String (browserNames[i]) + " " + cmdString.trim().quoted());

        cmdString = cmdLines.joinIntoString (" || ");
    }

    const char* const argv[4] = { "/bin/sh", "-c", cmdString.toUTF8(), 0 };

    const int cpid = fork();

    if (cpid == 0)
    {
        setsid();

        // Child process
        execve (argv[0], (char**) argv, environ);
        exit (0);
    }

    return cpid >= 0;
}

void File::revealToUser() const
{
    if (isDirectory())
        startAsProcess();
    else if (getParentDirectory().exists())
        getParentDirectory().startAsProcess();
}


#endif
