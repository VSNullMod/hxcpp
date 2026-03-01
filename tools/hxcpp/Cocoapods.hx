import haxe.io.Path;

#if haxe3
import BuildTool.Hash;
#end
import BuildTool.XmlAccess;

typedef CocoapodInfo = { version : String,
                         specPath : String,
                         podPath : String };

//developed against cocoapods 1.11.3

class Cocoapods
{
   private static var cocoapodVersions = new Map<String,String>();
   private static var cocoapods = new Map<String,CocoapodInfo>();

/* .xcframework/Info.plist example
<plist version="1.0">
<dict>
   <key>AvailableLibraries</key>
   <array>
      <dict>
         <key>LibraryIdentifier</key>
         <string>ios-armv7_arm64</string>
         <key>LibraryPath</key>
         <string>GoogleMobileAds.framework</string>
         <key>SupportedArchitectures</key>
         <array>
            <string>armv7</string>
            <string>arm64</string>
         </array>
         <key>SupportedPlatform</key>
         <string>ios</string>
      </dict>
      <dict>
         <key>LibraryIdentifier</key>
         <string>ios-i386_x86_64-simulator</string>
         <key>LibraryPath</key>
         <string>GoogleMobileAds.framework</string>
         <key>SupportedArchitectures</key>
         <array>
            <string>i386</string>
            <string>x86_64</string>
         </array>
         <key>SupportedPlatform</key>
         <string>ios</string>
         <key>SupportedPlatformVariant</key>
         <string>simulator</string>
      </dict>
   </array>
   <key>CFBundlePackageType</key>
   <string>XFWK</string>
   <key>XCFrameworkFormatVersion</key>
   <string>1.0</string>
</dict>
</plist>
*/

   public static function getActiveFrameworkSlice(xcframeworkPath:String, defines:Hash<String>):String
   {
      if (!StringTools.endsWith(xcframeworkPath, ".xcframework"))
      {
         Log.error("Can't get active framework slice of non-xc-framework: " + xcframeworkPath);
      }
      var infoPath = '$xcframeworkPath/Info.plist';

      var infoContents = "";
      try {
         infoContents = sys.io.File.getContent(infoPath);
      } catch (e:Dynamic) {
         Log.error("Could not open xcframework info plist \"" + infoPath + "\"");
      }

      var xmlSlow = Xml.parse(infoContents);
      //Document->plist->dict expected
      var xml = new XmlAccess(xmlSlow.firstElement().firstElement());

      var availableLibraries = getPlistValue(xml, "AvailableLibraries");
      if(availableLibraries == null)
      {
         Log.error("No available libraries in xcframework: \"" + infoPath + "\"");
      }

      var expectedArchitecture = "";
      if      (defines.exists("HXCPP_ARM64"))  expectedArchitecture = "arm64";
      else if (defines.exists("HXCPP_ARMV7"))  expectedArchitecture = "armv7";
      else if (defines.exists("HXCPP_X86_64")) expectedArchitecture = "x86_64";
      else                                     expectedArchitecture = "i386";

      for(dict in availableLibraries.elements)
      {
         var libraryIdentifier = getPlistString(dict, "LibraryIdentifier");
         var libraryPath = getPlistString(dict, "LibraryPath");
         var supportedArchitectures = getPlistStringArray(dict, "SupportedArchitectures");
         var supportedPlatform = getPlistString(dict, "SupportedPlatform");
         var supportedPlatformVariant = getPlistString(dict, "SupportedPlatformVariant");

         if(!defines.exists(supportedPlatform)) continue;
         if(supportedPlatformVariant != null && !defines.exists(supportedPlatformVariant)) continue;
         if(!supportedArchitectures.contains(expectedArchitecture)) continue;

         return '$xcframeworkPath/$libraryIdentifier/$libraryPath';
      }

      Log.error("Could not find active xcframework slice in \"" + xcframeworkPath + "\"");
      return "";
   }

   public static function getCocoapod (cocoapod:String, version:String, clearCache:Bool = false):CocoapodInfo
   {
      var name = '$cocoapod:$version';
      
      if (clearCache)
      {
         cocoapods.remove(name); 
      }
      
      if (!cocoapods.exists(name))
      {
         var cache = Log.verbose;
         Log.verbose = false;
         var output = "";
         
         try
         {
            output = ProcessManager.runProcess("", "pod", [ "cache", "list", cocoapod ], true, false);
         }
         catch (e:Dynamic) {}
         
         Log.verbose = cache;
         
         var lines = output.split("\n");
         /*
          *Google-Mobile-Ads-SDK:
          *  - Version: 7.59.0
          *    Type:    Release
          *    Spec:    /Users/justin/Library/Caches/CocoaPods/Pods/Specs/Release/Google-Mobile-Ads-SDK/7.59.0-11821.podspec.json
          *    Pod:     /Users/justin/Library/Caches/CocoaPods/Pods/Release/Google-Mobile-Ads-SDK/7.59.0-11821
          *  - Version: 7.68.0
          *    Type:    Release
          *    Spec:    /Users/justin/Library/Caches/CocoaPods/Pods/Specs/Release/Google-Mobile-Ads-SDK/7.68.0-29bbd.podspec.json
          *    Pod:     /Users/justin/Library/Caches/CocoaPods/Pods/Release/Google-Mobile-Ads-SDK/7.68.0-29bbd
         */
         var result = "";
         for (i in 1...lines.length)
         {
            if (lines[i] == '  - Version: $version')
            {
               var specPath = lines[i + 2].substr(13);
               var podPath = lines[i + 3].substr(13);
               Log.info("found installed cocoapod " + name);
               cocoapods.set(name, {version: version, specPath: specPath, podPath: podPath});
               break;
            }
         }
      }

      if (!cocoapods.exists(name))
      {
         Log.error("Could not find installed cocoapod \"" + name + "\"");
      }
      
      return cocoapods.get(name);
   }

   public static function getCocoapodVendoredFramework(cocoapod:String, version:String, framework:String, defines:Hash<String>, clearCache:Bool = false):String
   {
      var cocoapodInfo = getCocoapod(cocoapod, version, clearCache);
      if (cocoapodInfo != null)
      {
         var podSpecContents = "";
         try {
            podSpecContents = sys.io.File.getContent(cocoapodInfo.specPath);
         } catch (e:Dynamic) {
            Log.error("Could not open cocoapod spec \"" + cocoapodInfo.specPath + "\"");
            return "";
         }

         var podSpec = haxe.Json.parse(podSpecContents);
         var platform = getDefinedPlatform(defines);
         var platformFields = Reflect.field(podSpec, platform);
         if (platformFields == null && platform == "macos")
         {
            platformFields = podSpec.osx;
         }
         if (platformFields != null)
         {
            for (frameworkPath in getJsonStrings(platformFields, "vendored_frameworks"))
            {
               if (Path.withoutExtension(Path.withoutDirectory(frameworkPath)) == framework)
               {
                  return '${cocoapodInfo.podPath}/$frameworkPath';
               }
            }
         }
         for (frameworkPath in getJsonStrings(podSpec, "vendored_frameworks"))
         {
            if (Path.withoutExtension(Path.withoutDirectory(frameworkPath)) == framework)
            {
               return '${cocoapodInfo.podPath}/$frameworkPath';
            }
         }
      }
      
      Log.error("Could not find vendored framework \"" + framework + "\" in cocoapod \"" + cocoapod + "\"");
      return "";
   }

   private static function getJsonStrings(obj:Dynamic, key:String):Array<String>
   {
      if(!Reflect.hasField(obj, key))
         return [];
      var field:Dynamic = Reflect.field(obj, key);
      if(#if (haxe_ver >= 4.2) Std.isOfType #else Std.is #end (field, String))
         return [(field : String)];
      return (field : Array<String>);
   }

   public static function getDefinedPlatform(defines:Hash<String>):String
   {
      if(defines.exists("ios")) return "ios";
      if(defines.exists("macos")) return "macos";
      if(defines.exists("tvos")) return "tvos";
      if(defines.exists("watchos")) return "watchos";
      Log.error("Unknown platform (expected ios, macos, tvos, watchos).");
      return "";
   }

   public static function getPlistString(xml:XmlAccess, keyName:String):String
   {
      var value = getPlistValue(xml, keyName);
      if(value == null) return null;
      return value.innerHTML;
   }

   public static function getPlistStringArray(xml:XmlAccess, keyName:String):Array<String>
   {
      var value = getPlistValue(xml, keyName);
      if(value == null) return null;
      return [for (el in value.elements) el.innerHTML];
   }

   public static function getPlistValue(xml:XmlAccess, keyName:String):XmlAccess
   {
      var nextElement = false;
      for(el in xml.elements)
      {
         if(nextElement) return el;
         nextElement = (el.name == "key" && el.innerHTML == keyName);
      }

      return null;
   }

   public static function resolveCocoapodPathRequest(request:String, defines:Hash<String>):String
   {
      var parts = request.split(".");
      var pod = parts[0];
      var version = cocoapodVersions.get(pod);
      var toReturn = "";
      var nextPart = 1;

      if (parts.length > (nextPart + 1) && parts[nextPart] == "frameworks")
      {
         ++nextPart;
         toReturn = getCocoapodVendoredFramework(pod, version, parts[nextPart], defines);
         ++nextPart;

         if (parts.length > nextPart && parts[nextPart] == "active_slice")
         {
            ++nextPart;
            toReturn = getActiveFrameworkSlice(toReturn, defines);
         }
      }
      else if (parts.length > nextPart && parts[nextPart] == "path")
      {
         ++nextPart;
         var cocoapod = getCocoapod(pod, version);
         if(cocoapod != null)
            toReturn = cocoapod.podPath;
      }

      if (toReturn == "")
         Log.error("Cocoapod path request couldn't be resolved: " + request);

      if (parts.length > nextPart && parts[nextPart] == "dir")
      {
         ++nextPart;
         toReturn = Path.directory(toReturn);
      }

      return toReturn;
   }

   public static function setCocoapodVersion(cocoapod:String, version:String):Void
   {
      cocoapodVersions.set(cocoapod, version);
   }
}