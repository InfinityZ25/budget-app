require 'xcodeproj'
require 'fileutils'

root = File.expand_path(__dir__)
project_path = File.join(root, 'BudgetApp.xcodeproj')
FileUtils.rm_rf(project_path)
project = Xcodeproj::Project.new(project_path)

target = project.new_target(:application, 'BudgetApp', :ios, '17.0')
target.product_name = 'BudgetApp'

main_group = project.main_group.new_group('BudgetApp', 'Sources/BudgetApp')
Dir.glob(File.join(root, 'Sources/BudgetApp/**/*.swift')).sort.each do |file|
  relative = file.sub(root + '/', '')
  group_path = File.dirname(relative).sub('Sources/BudgetApp', '')
  group = main_group
  group_path.split('/').reject(&:empty?).each do |part|
    group = group.groups.find { |g| g.display_name == part } || group.new_group(part)
  end
  ref = group.new_file(relative)
  target.add_file_references([ref])
end

info_plist = File.join(root, 'BudgetApp', 'Info.plist')
FileUtils.mkdir_p(File.dirname(info_plist))
File.write(info_plist, <<~PLIST)
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>$(DEVELOPMENT_LANGUAGE)</string>
  <key>CFBundleExecutable</key>
  <string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key>
  <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>Budget</string>
  <key>CFBundlePackageType</key>
  <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSRequiresIPhoneOS</key>
  <true/>
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key>
    <false/>
  </dict>
  <key>UILaunchScreen</key>
  <dict/>
  <key>NSFinancialDataUsageDescription</key>
  <string>Budget uses financial account data to show balances, transactions, budgets, and cashflow projections.</string>
  <key>FinanceKitManagedEntitlementEnabled</key>
  <true/>
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST
plist_ref = project.main_group.new_file('BudgetApp/Info.plist')

entitlements_path = File.join(root, 'BudgetApp', 'BudgetApp.entitlements')
File.write(entitlements_path, <<~PLIST)
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.developer.financekit</key>
  <array>
    <string>financial-data</string>
  </array>
  <key>com.apple.developer.financekit.transaction-picker</key>
  <true/>
  <key>com.apple.developer.pass-type-identifiers</key>
  <array>
    <string>$(AppIdentifierPrefix)*</string>
  </array>
</dict>
</plist>
PLIST
project.main_group.new_file('BudgetApp/BudgetApp.entitlements')


project.build_configurations.each do |config|
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  config.build_settings['SWIFT_VERSION'] = '6.0'
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'
end

target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.hynix.budgetapp'
  config.build_settings['PRODUCT_NAME'] = 'Budget'
  config.build_settings['INFOPLIST_FILE'] = 'BudgetApp/Info.plist'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'NO'
  config.build_settings['ASSETCATALOG_COMPILER_APPICON_NAME'] = ''
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'BudgetApp/BudgetApp.entitlements'
  config.build_settings['DEVELOPMENT_TEAM'] = '764FPKS8YP'
  config.build_settings['MARKETING_VERSION'] = '1.0'
  config.build_settings['CURRENT_PROJECT_VERSION'] = '1'
  config.build_settings['SUPPORTED_PLATFORMS'] = 'iphoneos iphonesimulator'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1'
  config.build_settings['SWIFT_VERSION'] = '6.0'
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project_path, 'BudgetApp', true)
project.save
