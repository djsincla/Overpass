import Foundation
import Testing
@testable import SkyKit

@Suite struct RadarCrossSectionTests {
    let csv = """
    OBJECT_NAME,OBJECT_ID,NORAD_CAT_ID,OBJECT_TYPE,OPS_STATUS_CODE,OWNER,LAUNCH_DATE,LAUNCH_SITE,DECAY_DATE,PERIOD,INCLINATION,APOGEE,PERIGEE,RCS,DATA_STATUS_CODE,ORBIT_CENTER,ORBIT_TYPE
    VANGUARD 1,1958-002B,5,PAY,-,US,1958-03-17,AFETR,,132.65,34.25,3829,650,0.1220,,EA,ORB
    HST,1990-037B,20580,PAY,+,US,1990-04-24,AFETR,,93.99,28.47,471,468,28.0799,,EA,ORB
    "ODD, NAME",1998-067A,25544,PAY,+,ISS,1998-11-20,TYMSC,,92.96,51.63,424,415,399.0524,,EA,ORB
    CSS (TIANHE),2021-035A,48274,PAY,+,PRC,2021-04-29,WSC,,92.24,41.47,386,383,,,EA,ORB
    """

    @Test func parsesPublishedValuesAndSkipsBlanks() {
        let rcs = RadarCrossSection.parse(csv)
        #expect(rcs["20580"] == 28.0799)
        #expect(rcs["25544"] == 399.0524)  // a quoted name with a comma doesn't shift the columns
        #expect(rcs["48274"] == nil)
        #expect(rcs.count == 3)
    }

    @Test func leadingZerosMatch() {
        let rcs = RadarCrossSection.parse(csv)
        #expect(rcs[RadarCrossSection.key("00005")] == 0.122)
        #expect(RadarCrossSection.key(" 25544") == "25544")
    }

    @Test func noHeaderNoValues() {
        #expect(RadarCrossSection.parse("garbage\n1,2,3").isEmpty)
    }
}
