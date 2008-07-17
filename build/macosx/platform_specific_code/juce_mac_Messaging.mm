/*
  ==============================================================================

   This file is part of the JUCE library - "Jules' Utility Class Extensions"
   Copyright 2004-7 by Raw Material Software ltd.

  ------------------------------------------------------------------------------

   JUCE can be redistributed and/or modified under the terms of the
   GNU General Public License, as published by the Free Software Foundation;
   either version 2 of the License, or (at your option) any later version.

   JUCE is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
   GNU General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with JUCE; if not, visit www.gnu.org/licenses or write to the
   Free Software Foundation, Inc., 59 Temple Place, Suite 330,
   Boston, MA 02111-1307 USA

  ------------------------------------------------------------------------------

   If you'd like to release a closed-source product which uses JUCE, commercial
   licenses are also available: visit www.rawmaterialsoftware.com/juce for
   more information.

  ==============================================================================
*/

#include "juce_mac_NativeHeaders.h"
#include <Carbon/Carbon.h>

BEGIN_JUCE_NAMESPACE

#include "../../../src/juce_appframework/events/juce_MessageManager.h"
#include "../../../src/juce_appframework/application/juce_Application.h"
#include "../../../src/juce_appframework/gui/components/juce_Desktop.h"
#include "../../../src/juce_core/text/juce_StringArray.h"
#include "../../../src/juce_core/threads/juce_Thread.h"
#include "../../../src/juce_core/misc/juce_PlatformUtilities.h"

#undef Point

extern void juce_HandleProcessFocusChange();
extern void juce_maximiseAllMinimisedWindows();
extern void juce_InvokeMainMenuCommand (const HICommand& command);
extern void juce_MainMenuAboutToBeUsed();

struct CallbackMessagePayload
{
    MessageCallbackFunction* function;
    void* parameter;
    void* volatile result;
    bool volatile hasBeenExecuted;
};

END_JUCE_NAMESPACE

#if JUCE_COCOA

NSString* juceMessageName = 0;

@interface JuceAppDelegate   : NSObject
id oldDelegate;
- (JuceAppDelegate*) init;
- (void) dealloc;
- (BOOL) application: (NSApplication*) theApplication openFile: (NSString*) filename;
- (void) application: (NSApplication*) sender openFiles: (NSArray*) filenames;
- (NSApplicationTerminateReply) applicationShouldTerminate: (NSApplication*) app;
- (void) applicationDidBecomeActive: (NSNotification*) aNotification;
- (void) applicationDidResignActive: (NSNotification*) aNotification;
- (void) applicationWillUnhide: (NSNotification*) aNotification;
- (void) customEvent: (NSNotification*) aNotification;
- (void) performCallback: (id) info;
@end

@implementation JuceAppDelegate

- (JuceAppDelegate*) init
{
    [super init];

    NSNotificationCenter* center = [NSNotificationCenter defaultCenter];

    if (JUCE_NAMESPACE::JUCEApplication::getInstance() != 0)
    {
        oldDelegate = [NSApp delegate];
        [NSApp setDelegate: self];
    }
    else
    {
        oldDelegate = 0;
        [center addObserver: self selector: @selector (applicationDidResignActive:)  
                       name: NSApplicationDidResignActiveNotification object: NSApp];

        [center addObserver: self selector: @selector (applicationDidBecomeActive:)  
                       name: NSApplicationDidBecomeActiveNotification object: NSApp];

        [center addObserver: self selector: @selector (applicationWillUnhide:)  
                       name: NSApplicationWillUnhideNotification object: NSApp];

    }

    [center addObserver: self selector: @selector (customEvent:)  
                   name: juceMessageName object: nil];

    return self;
}

- (void) dealloc
{
    if (oldDelegate != 0)
        [NSApp setDelegate: oldDelegate];

    [[NSNotificationCenter defaultCenter] removeObserver: self];
    [super dealloc];
}

- (NSApplicationTerminateReply) applicationShouldTerminate: (NSApplication*) app
{
    if (JUCE_NAMESPACE::JUCEApplication::getInstance() != 0)
        JUCE_NAMESPACE::JUCEApplication::getInstance()->systemRequestedQuit();

    return NSTerminateLater;
}

- (BOOL) application: (NSApplication*) app openFile: (NSString*) filename
{
    if (JUCE_NAMESPACE::JUCEApplication::getInstance() != 0)
    {
        JUCE_NAMESPACE::JUCEApplication::getInstance()->anotherInstanceStarted (nsStringToJuce (filename));
        return YES;
    }

    return NO;
}

- (void) application: (NSApplication*) sender openFiles: (NSArray*) filenames
{
    JUCE_NAMESPACE::StringArray files;
    for (int i = 0; i < [filenames count]; ++i)
        files.add (nsStringToJuce ((NSString*) [filenames objectAtIndex: i]));

    if (files.size() > 0 && JUCE_NAMESPACE::JUCEApplication::getInstance() != 0)
        JUCE_NAMESPACE::JUCEApplication::getInstance()->anotherInstanceStarted (files.joinIntoString (T(" ")));
}

- (void) applicationDidBecomeActive: (NSNotification*) aNotification
{
    JUCE_NAMESPACE::juce_HandleProcessFocusChange();
}

- (void) applicationDidResignActive: (NSNotification*) aNotification
{
    JUCE_NAMESPACE::juce_HandleProcessFocusChange();
}

- (void) applicationWillUnhide: (NSNotification*) aNotification
{
    JUCE_NAMESPACE::juce_maximiseAllMinimisedWindows();
}

- (void) customEvent: (NSNotification*) n
{
    void* message = 0;
    [((NSData*) [n object]) getBytes: &message length: sizeof (message)];

    if (message != 0)
        JUCE_NAMESPACE::MessageManager::getInstance()->deliverMessage (message);
}

- (void) performCallback: (id) info
{
    JUCE_NAMESPACE::CallbackMessagePayload* pl = (JUCE_NAMESPACE::CallbackMessagePayload*) info;

    if (pl != 0)
    {
        pl->result = (*pl->function) (pl->parameter);
        pl->hasBeenExecuted = true;
    }
}

@end
#endif

BEGIN_JUCE_NAMESPACE


#if JUCE_COCOA
static JuceAppDelegate* juceAppDelegate = 0;

#else
static int kJUCEClass = FOUR_CHAR_CODE ('JUCE');
const int kJUCEKind = 1;
const int kCallbackKind = 2;


static pascal OSStatus EventHandlerProc (EventHandlerCallRef, EventRef theEvent, void* userData)
{
    void* event = 0;
    GetEventParameter (theEvent, 'mess', typeVoidPtr, 0, sizeof (void*), 0, &event);

    if (event != 0)
        MessageManager::getInstance()->deliverMessage (event);

    return noErr;
}

static pascal OSStatus CallbackHandlerProc (EventHandlerCallRef, EventRef theEvent, void* userData)
{
    CallbackMessagePayload* pl = 0;
    GetEventParameter (theEvent, 'mess', typeVoidPtr, 0, sizeof(pl), 0, &pl);

    if (pl != 0)
    {
        pl->result = (*pl->function) (pl->parameter);
        pl->hasBeenExecuted = true;
    }

    return noErr;
}

static pascal OSStatus MouseClickHandlerProc (EventHandlerCallRef, EventRef theEvent, void* userData)
{
    ::Point where;
    GetEventParameter (theEvent, kEventParamMouseLocation, typeQDPoint, 0, sizeof(::Point), 0, &where);
    WindowRef window;
    if (FindWindow (where, &window) == inMenuBar)
    {
        // turn off the wait cursor before going in here..
        const int oldTimeBeforeWaitCursor = MessageManager::getInstance()->getTimeBeforeShowingWaitCursor();
        MessageManager::getInstance()->setTimeBeforeShowingWaitCursor (0);

        if (Component::getCurrentlyModalComponent() != 0)
            Component::getCurrentlyModalComponent()->inputAttemptWhenModal();

        juce_MainMenuAboutToBeUsed();
        MenuSelect (where);
        HiliteMenu (0);

        MessageManager::getInstance()->setTimeBeforeShowingWaitCursor (oldTimeBeforeWaitCursor);
        return noErr;
    }

    return eventNotHandledErr;
}

static pascal OSErr QuitAppleEventHandler (const AppleEvent *appleEvt, AppleEvent* reply, long refcon)
{
    if (JUCEApplication::getInstance() != 0)
        JUCEApplication::getInstance()->systemRequestedQuit();

    return noErr;
}

static pascal OSErr OpenDocEventHandler (const AppleEvent *appleEvt, AppleEvent* reply, long refcon)
{
    AEDescList docs;
    StringArray files;

    if (AEGetParamDesc (appleEvt, keyDirectObject, typeAEList, &docs) == noErr)
    {
        long num;
        if (AECountItems (&docs, &num) == noErr)
        {
            for (int i = 1; i <= num; ++i)
            {
                FSRef file;
                AEKeyword keyword;
                DescType type;
                Size size;

                if (AEGetNthPtr (&docs, i, typeFSRef, &keyword, &type,
                                 &file, sizeof (file), &size) == noErr)
                {
                    const String path (PlatformUtilities::makePathFromFSRef (&file));

                    if (path.isNotEmpty())
                        files.add (path.quoted());
                }
            }

            if (files.size() > 0
                 && JUCEApplication::getInstance() != 0)
            {
                JUCE_TRY
                {
                    JUCEApplication::getInstance()
                        ->anotherInstanceStarted (files.joinIntoString (T(" ")));
                }
                JUCE_CATCH_ALL
            }
        }

        AEDisposeDesc (&docs);
    };

    return noErr;
}

static pascal OSStatus AppEventHandlerProc (EventHandlerCallRef, EventRef theEvent, void* userData)
{
    const UInt32 eventClass = GetEventClass (theEvent);

    if (eventClass == kEventClassCommand)
    {
        HICommand command;

        if (GetEventParameter (theEvent, kEventParamHICommand, typeHICommand, 0, sizeof (command), 0, &command) == noErr
            || GetEventParameter (theEvent, kEventParamDirectObject, typeHICommand, 0, sizeof (command), 0, &command) == noErr)
        {
            if (command.commandID == kHICommandQuit)
            {
                if (JUCEApplication::getInstance() != 0)
                    JUCEApplication::getInstance()->systemRequestedQuit();

                return noErr;
            }
            else if (command.commandID == kHICommandMaximizeAll
                      || command.commandID == kHICommandMaximizeWindow
                      || command.commandID == kHICommandBringAllToFront)
            {
                juce_maximiseAllMinimisedWindows();
                return noErr;
            }
            else
            {
                juce_InvokeMainMenuCommand (command);
            }
        }
    }
    else if (eventClass == kEventClassApplication)
    {
        if (GetEventKind (theEvent) == kEventAppFrontSwitched)
        {
            juce_HandleProcessFocusChange();
        }
        else if (GetEventKind (theEvent) == kEventAppShown)
        {
            // this seems to blank the windows, so we need to do a repaint..
            for (int i = Desktop::getInstance().getNumComponents(); --i >= 0;)
            {
                Component* const c = Desktop::getInstance().getComponent (i);

                if (c != 0)
                    c->repaint();
            }
        }
    }

    return eventNotHandledErr;
}

static EventQueueRef mainQueue;
static EventHandlerRef juceEventHandler = 0;
static EventHandlerRef callbackEventHandler = 0;

#endif

//==============================================================================
void MessageManager::doPlatformSpecificInitialisation()
{
    static bool initialised = false;

    if (! initialised)
    {
        initialised = true;

#if JUCE_COCOA
        // if we're linking a Juce app to one or more dynamic libraries, we'll need different values
        // for this so each module doesn't interfere with the others.
        UnsignedWide t;
        Microseconds (&t);
        kJUCEClass ^= t.lo;

        juceMessageName = juceStringToNS ("juce_" + String::toHexString ((int) t.lo));

        juceAppDelegate = [[JuceAppDelegate alloc] init];
#else
        mainQueue = GetMainEventQueue();
#endif
    }

#if ! JUCE_COCOA
    const EventTypeSpec type1 = { kJUCEClass, kJUCEKind };
    InstallApplicationEventHandler (NewEventHandlerUPP (EventHandlerProc), 1, &type1, 0, &juceEventHandler);

    const EventTypeSpec type2 = { kJUCEClass, kCallbackKind };
    InstallApplicationEventHandler (NewEventHandlerUPP (CallbackHandlerProc), 1, &type2, 0, &callbackEventHandler);

    // only do this stuff if we're running as an application rather than a library..
    if (JUCEApplication::getInstance() != 0)
    {
        const EventTypeSpec type3 = { kEventClassMouse, kEventMouseDown };
        InstallApplicationEventHandler (NewEventHandlerUPP (MouseClickHandlerProc), 1, &type3, 0, 0);

        const EventTypeSpec type4[] = { { kEventClassApplication, kEventAppShown },
                                        { kEventClassApplication, kEventAppFrontSwitched },
                                        { kEventClassCommand, kEventProcessCommand } };

        InstallApplicationEventHandler (NewEventHandlerUPP (AppEventHandlerProc), 3, type4, 0, 0);

        AEInstallEventHandler (kCoreEventClass, kAEQuitApplication,
                               NewAEEventHandlerUPP (QuitAppleEventHandler), 0, false);

        AEInstallEventHandler (kCoreEventClass, kAEOpenDocuments,
                               NewAEEventHandlerUPP (OpenDocEventHandler), 0, false);
    }
#endif
}

void MessageManager::doPlatformSpecificShutdown()
{
    if (juceEventHandler != 0)
    {
        RemoveEventHandler (juceEventHandler);
        juceEventHandler = 0;
    }

    if (callbackEventHandler != 0)
    {
        RemoveEventHandler (callbackEventHandler);
        callbackEventHandler = 0;
    }
}

bool juce_postMessageToSystemQueue (void* message)
{
#if JUCE_COCOA
    [[NSNotificationCenter defaultCenter] postNotificationName: juceMessageName
                                                        object: [NSData dataWithBytes: &message 
                                                                               length: (int) sizeof (message)]];

    return true;

#else
    jassert (mainQueue == GetMainEventQueue());

    EventRef event;
    if (CreateEvent (0, kJUCEClass, kJUCEKind, 0, kEventAttributeUserEvent, &event) == noErr)
    {
        SetEventParameter (event, 'mess', typeVoidPtr, sizeof (void*), &message);
        const bool ok = PostEventToQueue (mainQueue, event, kEventPriorityStandard) == noErr;
        ReleaseEvent (event);
        return ok;
    }

    return false;
#endif
}

void MessageManager::broadcastMessage (const String& value) throw()
{
}

void* MessageManager::callFunctionOnMessageThread (MessageCallbackFunction* callback,
                                                   void* data)
{
    if (isThisTheMessageThread())
    {
        return (*callback) (data);
    }
    else
    {
        CallbackMessagePayload cmp;
        cmp.function = callback;
        cmp.parameter = data;
        cmp.result = 0;
        cmp.hasBeenExecuted = false;

#if JUCE_COCOA
        [juceAppDelegate performSelectorOnMainThread: @selector (performCallback:)
                                          withObject: (id) &cmp
                                       waitUntilDone: YES];

        return cmp.result;

#else
        jassert (mainQueue == GetMainEventQueue());

        EventRef event;
        if (CreateEvent (0, kJUCEClass, kCallbackKind, 0, kEventAttributeUserEvent, &event) == noErr)
        {
            void* v = &cmp;
            SetEventParameter (event, 'mess', typeVoidPtr, sizeof (void*), &v);

            if (PostEventToQueue (mainQueue, event, kEventPriorityStandard) == noErr)
            {
                while (! cmp.hasBeenExecuted)
                    Thread::yield();

                return cmp.result;
            }
        }

        return 0;
#endif
    }
}

END_JUCE_NAMESPACE
